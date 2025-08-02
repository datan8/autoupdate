using namespace System.Net

param($Request, $TriggerMetadata)

# --- Environment Setup and Configuration ---

Write-Host "⚙️ Initializing function..."
Write-Host "Request: $($Request | ConvertTo-Json -Depth 10)"

# Load all required settings from environment variables
$settings = @{
    SendGridKey             = $env:SENDGRID_API_KEY
    EmailTo                 = $env:EMAIL_TO
    EmailFrom               = $env:EMAIL_FROM
    GhlApiKey               = $env:GHL_API_KEY
    GhlLocationId           = $env:GHL_LOCATION_ID
    GhlDomain               = $env:GHL_DOMAIN
    OpenAIKey               = $env:OPENAI_API_KEY
    OpenAIModel             = $env:OPENAI_MODEL
    GitHubToken             = $env:GITHUB_TOKEN
    GitHubOrg               = $env:GITHUB_ORG
    TemplateRepo            = $env:GITHUB_TEMPLATE_REPO
    AzureResourceGroupPrd   = $env:AZURE_RESOURCE_GROUP_PRD
    AzureResourceGroupUat   = $env:AZURE_RESOURCE_GROUP_UAT
    AzureLocation           = $env:AZURE_LOCATION
    AzureSubscriptionId     = $env:AZURE_SUBSCRIPTION_ID
    ProdStorageAccount      = $env:PROD_STORAGE_ACCOUNT
    TestStorageAccount      = $env:TEST_STORAGE_ACCOUNT
    FrontDoorProfileName    = $env:FRONT_DOOR_PROFILE_NAME
}

# Validate that all settings are present
$missingSettings = $settings.Keys | Where-Object { [string]::IsNullOrEmpty($settings[$_]) }
if ($missingSettings) {
    throw "Missing required environment variables: $($missingSettings -join ', ')"
}

# Only connect to Azure if running locally (Azure Functions uses managed identity automatically)
if ($env:AZURE_FUNCTIONS_ENVIRONMENT -eq "Development") {
    # Connect to Azure with the correct subscription
    Write-Host "Connecting to Azure with subscription: $($settings.AzureSubscriptionId)"
    Connect-AzAccount -SubscriptionId $settings.AzureSubscriptionId -ErrorAction Stop
    Write-Host "✅ Connected to Azure."
}
# API Headers
$ghlHeaders = @{ "Authorization" = "Bearer $($settings.GhlApiKey)"; "Content-Type" = "application/json" }
$gitHubHeaders = @{ "Authorization" = "Bearer $($settings.GitHubToken)"; "Accept" = "application/vnd.github+json" }
$openAIHeaders = @{ "Authorization" = "Bearer $($settings.OpenAIKey)"; "Content-Type" = "application/json" }
$sendGridHeaders = @{ "Authorization" = "Bearer $($settings.SendGridKey)"; "Content-Type" = "application/json" }


# --- Helper Functions ---

function New-FederatedCredentialWithRetry {
    param(
        [string]$ApplicationObjectId,
        [string]$Name,
        [string]$Subject,
        [int]$MaxRetries = 3
    )
    
    Write-Host "     🔗 Creating federated credential '$Name' for subject: $Subject"
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            New-AzADAppFederatedCredential -ApplicationObjectId $ApplicationObjectId -Issuer "https://token.actions.githubusercontent.com" -Name $Name -Audience "api://AzureADTokenExchange" -Subject $Subject -ErrorAction Stop
            Write-Host "     ✅ Federated credential '$Name' created successfully"
            return $true
        } catch {
            if ($attempt -eq $MaxRetries) {
                Write-Warning "     ❌ Failed to create federated credential after $MaxRetries attempts: $($_.Exception.Message)"
                return $false
            } else {
                Write-Host "     ⏳ Attempt $attempt failed, retrying in 5 seconds..."
                Start-Sleep -Seconds 5
            }
        }
    }
}

function Get-OrCreateFederatedCredential {
    param(
        [string]$ApplicationObjectId,
        [string]$Name,
        [string]$Subject
    )
    
    # First try to get existing credential - get all and filter by name
    $allCreds = Get-AzADAppFederatedCredential -ApplicationObjectId $ApplicationObjectId -ErrorAction SilentlyContinue
    $existingCred = $allCreds | Where-Object { $_.Name -eq $Name }
    if ($existingCred) {
        if ($existingCred.Subject -eq $Subject) {
            Write-Host "     ℹ️ Found existing federated credential '$Name' with matching subject."
        return $true
        }

        Write-Host "     ⚠️ Existing federated credential '$Name' subject mismatch. Recreating..."
        try {
            Remove-AzADAppFederatedCredential -ApplicationObjectId $ApplicationObjectId -FederatedCredentialId $existingCred.Id -ErrorAction Stop
            Write-Host "     🗑️ Removed old federated credential '$Name'"
        }
        catch {
            Write-Warning "     ❌ Failed to remove old federated credential '$Name': $($_.Exception.Message)"
        }

        # Create new credential with desired subject
        return New-FederatedCredentialWithRetry -ApplicationObjectId $ApplicationObjectId -Name $Name -Subject $Subject
    }
    
    # Try to create new credential
    return New-FederatedCredentialWithRetry -ApplicationObjectId $ApplicationObjectId -Name $Name -Subject $Subject
}

function Rename-GitHubDirectory {
    param(
        [string]$org,
        [string]$repo,
        [string]$oldPath,
        [string]$newPath,
        [hashtable]$headers,
        [string]$branch = "main"
    )

    try {
        Write-Host "   🔄 Renaming directory '$oldPath' to '$newPath' via Git data API..."

        $ProgressPreference = 'SilentlyContinue'  # speed up Invoke-RestMethod

        # 1. Get the reference for the branch (retry because GitHub may take a moment to create refs on newly generated repos)
        $refUrl = "https://api.github.com/repos/$org/$repo/git/refs/heads/$branch"
        Write-Host "   📍 Step 1: Getting branch ref from $refUrl"
        $maxAttempts = 10
        $attempt = 0
        $refInfo = $null
        while (-not $refInfo -and $attempt -lt $maxAttempts) {
            try {
                $refInfo = Invoke-RestMethod -Method GET -Uri $refUrl -Headers $headers -ErrorAction Stop
            }
            catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                    $attempt++
                    Write-Host "   ⏳ Branch ref not found yet (attempt $attempt/$maxAttempts). Waiting 3s..."
                    Start-Sleep -Seconds 3
                }
                else { throw }
            }
        }
        if (-not $refInfo) { throw "Branch '$branch' not found after retries" }
        $baseCommitSha = $refInfo.object.sha
        Write-Host "   ✅ Step 1: Got commit SHA $baseCommitSha"

        # 2. Get the commit object to retrieve the base tree SHA
        Write-Host "   📍 Step 2: Getting commit object for SHA $baseCommitSha"

        $maxTreeAttempts = 10
        $treeAttempt     = 0
        $baseTreeSha     = $null

        do {
            try {
                $commitInfo  = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$org/$repo/git/commits/$baseCommitSha" -Headers $headers -ErrorAction Stop
                $baseTreeSha = $commitInfo.tree.sha

                if (-not [string]::IsNullOrWhiteSpace($baseTreeSha)) {
                    Write-Host "   ✅ Step 2: Got tree SHA $baseTreeSha"
                    break
                } else {
                    Write-Host "   ⏳ Tree SHA empty (attempt $($treeAttempt + 1)/$maxTreeAttempts). Waiting 3s..."
                }
            }
            catch {
                Write-Host "   ⚠️  Failed to get commit (attempt $($treeAttempt + 1)/$maxTreeAttempts): $($_.Exception.Message)"
            }

            $treeAttempt++
            Start-Sleep -Seconds 3
        } while ($treeAttempt -lt $maxTreeAttempts)

        if ([string]::IsNullOrWhiteSpace($baseTreeSha)) {
            throw "Base tree SHA not found after $maxTreeAttempts attempts – repository may still be initialising."
        }
        
        # 3. Retrieve the full tree recursively
        Write-Host "   📍 Step 3: Getting tree recursively for SHA $baseTreeSha"
        $treeUrl = "https://api.github.com/repos/$org/$repo/git/trees/${baseTreeSha}?recursive=1"
        Write-Host "   🌐 Request URL: $treeUrl"

        $treeResponse = $null
        $treeError    = $null

        try {
            $treeResponse = Invoke-WebRequest -Method GET -Uri $treeUrl -Headers $headers -ErrorAction Stop
        }
        catch {
            $treeError = $_
            Write-Host "   ❌ Step 3 failed"
            Write-Host "   🛑 Full error details:`n$($treeError | Out-String)"
        }
        
        if ($treeError) {
            throw $treeError
        }
        
        $treeInfo = $treeResponse.Content | ConvertFrom-Json
        if ($treeInfo.truncated) {
            throw "Tree response is truncated; cannot rename large directories reliably."
        }
        Write-Host "   ✅ Step 3: Got tree with $($treeInfo.tree.Count) entries"

        $entries = $treeInfo.tree | Where-Object { $_.type -eq 'blob' -and $_.path -like "$oldPath/*" }
        Write-Host "   🔍 Found $($entries.Count) items under '$oldPath' to move."

        if ($entries.Count -eq 0) {
            throw "No blobs found under path '$oldPath'. Verify the directory exists in the repository."
        }

        $changes = @()
        foreach ($entry in $entries) {
            $relative = $entry.path.Substring($oldPath.Length + 1)  # remove prefix and slash
            $newEntryPath = "$newPath/$relative"
            $changes += @{ path = $newEntryPath; mode = $entry.mode; type = 'blob'; sha = $entry.sha }
            $changes += @{ path = $entry.path; mode = $entry.mode; type = 'blob'; sha = $null }
        }

        # 4. Create a new tree with the accumulated changes
        Write-Host "   📍 Step 4: Creating new tree with $($changes.Count) changes"
        $newTree = Invoke-RestMethod -Method POST -Uri "https://api.github.com/repos/$org/$repo/git/trees" -Headers $headers -Body (@{ base_tree = $baseTreeSha; tree = $changes } | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop
        Write-Host "   ✅ Step 4: Created new tree SHA $($newTree.sha)"

        # 5. Create a new commit that points to the new tree
        Write-Host "   📍 Step 5: Creating new commit"
        $newCommit = Invoke-RestMethod -Method POST -Uri "https://api.github.com/repos/$org/$repo/git/commits" -Headers $headers -Body (@{ message = "Rename $oldPath to $newPath"; tree = $newTree.sha; parents = @($baseCommitSha) } | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop
        Write-Host "   ✅ Step 5: Created new commit SHA $($newCommit.sha)"

        # 6. Update the branch reference to the new commit
        Write-Host "   📍 Step 6: Updating branch ref to new commit"
        Start-Sleep -Seconds 10
        Invoke-RestMethod -Method PATCH -Uri $refUrl -Headers $headers -Body (@{ sha = $newCommit.sha; force = $false } | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
        Write-Host "   ✅ Step 6: Updated branch ref"

        Write-Host "   ✅ Directory renamed successfully in commit $($newCommit.sha)"
    }
    catch {
        # Attempt to extract verbose error details
        $msg = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.Content) {
            try {
                $statusCode = $_.Exception.Response.StatusCode.value__
                $statusDesc = $_.Exception.Response.StatusDescription
                $respBody = $_.Exception.Response.Content.ReadAsStringAsync().Result
                $msg = "HTTP $statusCode $statusDesc - $respBody"
            } catch {}
        }
        throw "Rename-GitHubDirectory failed: $msg"
    }
}

function Send-RawJsonEmail {
    param([PSCustomObject]$leadData)
    
    Write-Host "📧 Sending raw JSON to admin@datan8.com"
    
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 800px; margin: 0 auto; padding: 20px; }
        .header { background-color: #dc3545; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .json-content { background-color: #f8f9fa; padding: 20px; border-radius: 5px; margin: 10px 0; }
        .json-code { white-space: pre-wrap; font-family: 'Courier New', monospace; font-size: 12px; line-height: 1.4; background-color: #f5f5f5; padding: 15px; border-radius: 5px; overflow-x: auto; border: 1px solid #ddd; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>📋 Raw Lead Data Received</h2>
            <p><strong>Timestamp:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
        </div>

        <div class="json-content">
            <h3>Complete JSON Payload:</h3>
            <div class="json-code">$(($leadData | ConvertTo-Json -Depth 10) -replace '<', '<' -replace '>', '>')</div>
        </div>

        <div class="footer">
            <p>This email was automatically generated by the NowSites Setup Script.</p>
            <p>Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
        </div>
    </div>
</body>
</html>
"@

    $textContent = @"
Raw Lead Data Received

Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')

Complete JSON Payload:
=====================================
$($leadData | ConvertTo-Json -Depth 10)

---
This email was automatically generated by the NowSites Setup Script.
Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')
"@

    $emailBody = @{
        personalizations = @(@{ to = @(@{ email = "admin@datan8.com" }) })
        from             = @{ email = $settings.EmailFrom }
        subject          = "📋 Raw Lead Data - $($leadData.lead.businessName)"
        content          = @(
            @{ type = "text/plain"; value = $textContent },
            @{ type = "text/html"; value = $htmlContent }
        )
        tracking_settings = @{
            click_tracking = @{ enable = $false }
            open_tracking = @{ enable = $false }
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://api.sendgrid.com/v3/mail/send" -Method Post -Headers $sendGridHeaders -Body $emailBody -ErrorAction Stop
        Write-Host "✅ Raw JSON email sent successfully to admin@datan8.com"
    }
    catch {
        Write-Warning "Failed to send raw JSON email: $($_.Exception.Message)"
    }
}

function Send-LeadConfirmationEmail {
    param([string]$leadEmail, [string]$leadName, [PSCustomObject]$leadData)
    
    Write-Host "📧 Sending confirmation email to lead: $leadEmail"
    
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background-color: #007bff; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .content { background-color: #f8f9fa; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .details { background-color: #e7f3ff; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .details h4 { margin-top: 0; color: #007bff; }
        .details ul { margin: 10px 0; padding-left: 20px; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🚀 Thanks for Your Website Request!</h2>
        </div>
        <div class="content">
            <p>Hi $leadName,</p>
            <p>Thank you for requesting a website preview from NowSites! We're excited to help bring your vision to life.</p>
            
            <div class="details">
                <h4>📋 Your Request Summary:</h4>
                <ul>
                    <li><strong>Business Name:</strong> $($leadData.lead.businessName)</li>
                    <li><strong>Contact:</strong> $($leadData.lead.contactName)</li>
                    <li><strong>Email:</strong> $($leadData.lead.email)</li>
                    <li><strong>Phone:</strong> $($leadData.lead.phone)</li>
                    <li><strong>Business Description:</strong> $($leadData.websiteRequirements.businessDescription)</li>
                    <li><strong>Pages Requested:</strong> $($leadData.pageRequirements.requestedPages -join ", ")</li>
                    <li><strong>Websites You Like:</strong> $($leadData.websiteRequirements.otherWebsitesLike)</li>
                    <li><strong>Additional Notes:</strong> $($leadData.projectDetails.additionalNotes)</li>
                </ul>
            </div>
            
            <p><strong>What's happening now:</strong></p>
            <ul>
                <li>✅ Your request has been received</li>
                <li>🔧 Our team is setting up your project infrastructure</li>
                <li>🎨 We're preparing to create your custom website</li>
            </ul>
            <p>We'll be in touch shortly with your website preview and next steps.</p>
            <p>If you have any questions in the meantime, feel free to reach out!</p>
            <p>Best regards,<br>The NowSites Team</p>
        </div>
        <div class="footer">
            <p>This is an automated message from NowSites.</p>
            <p>Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
        </div>
    </div>
</body>
</html>
"@

    $textContent = @"
Thanks for Your Website Request!

Hi $leadName,

Thank you for requesting a website preview from NowSites! We're excited to help bring your vision to life.

Your Request Summary:
- Business Name: $($leadData.lead.businessName)
- Contact: $($leadData.lead.contactName)
- Email: $($leadData.lead.email)
- Phone: $($leadData.lead.phone)
- Business Description: $($leadData.websiteRequirements.businessDescription)
- Pages Requested: $($leadData.pageRequirements.requestedPages -join ", ")
- Websites You Like: $($leadData.websiteRequirements.otherWebsitesLike)
- Additional Notes: $($leadData.projectDetails.additionalNotes)

What's happening now:
✅ Your request has been received
🔧 Our team is setting up your project infrastructure  
🎨 We're preparing to create your custom website

We'll be in touch shortly with your website preview and next steps.

If you have any questions in the meantime, feel free to reach out!

Best regards,
The NowSites Team

---
This is an automated message from NowSites.
Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')
"@

    $emailBody = @{
        personalizations = @(@{ to = @(@{ email = $leadEmail }) })
        from             = @{ email = $settings.EmailFrom }
        subject          = "Thanks for your website request - We're getting started!"
        content          = @(
            @{ type = "text/plain"; value = $textContent },
            @{ type = "text/html"; value = $htmlContent }
        )
        bcc              = @(@{ email = "admin@datan8.com" })
        tracking_settings = @{
            click_tracking = @{ enable = $false }
            open_tracking = @{ enable = $false }
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://api.sendgrid.com/v3/mail/send" -Method Post -Headers $sendGridHeaders -Body $emailBody -ErrorAction Stop
        Write-Host "✅ Confirmation email sent successfully."
    }
    catch {
        Write-Warning "❌ Failed to send lead confirmation email: $($_.Exception.Message)"
    }
}

function Get-OrCreateGhlPipeline {
    param($headers)
    Write-Host "📈 Getting or creating GHL 'Leads' pipeline..."
    $pipelines = (Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/pipelines" -Method Get -Headers $headers).pipelines
    $pipeline = $pipelines | Where-Object { $_.name -eq "Leads" }

    if (-not $pipeline) {
        Write-Host "   'Leads' pipeline not found. Creating..."
        $pipelineBody = @{ name = "Leads" } | ConvertTo-Json
        $pipeline = Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/pipelines" -Method Post -Headers $headers -Body $pipelineBody
        Write-Host "   ✅ Created pipeline ID: $($pipeline.id)"
    }
    $stage = $pipeline.stages | Where-Object { $_.name -eq "New Leads" }
    if (-not $stage) {
        # A new pipeline doesn't have this stage by default in the API response, so we may need to re-fetch or assume it needs creating.
        # For now, we'll assume the first stage is correct or it exists. A more robust solution might add a stage if missing.
        $stage = $pipeline.stages[0]
        Write-Warning "   Could not find 'New Leads' stage, using first available stage: $($stage.name)"
    }
    Write-Host "✅ Pipeline and stage IDs retrieved."
    return @{ PipelineId = $pipeline.id; StageId = $stage.id }
}

function Get-OrCreateGhlContact {
    param($headers, [hashtable]$contact)
    Write-Host "👤 Getting or creating GHL contact for $($contact.email)..."
    $encodedEmail = [uri]::EscapeDataString($contact.email)
    $contactResult = Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/contacts/lookup?email=$encodedEmail" -Method Get -Headers $headers
    
    if ($contactResult.contacts.Count -gt 0) {
        $contactId = $contactResult.contacts[0].id
        Write-Host "   ✅ Found existing contact with ID: $contactId"
        return $contactId
    }

    Write-Host "   No contact found. Creating..."
    $contactBody = @{
        firstName = $contact.firstName
        email     = $contact.email
        phone     = $contact.phone
        name      = "$($contact.firstName) $($contact.lastName)"
    } | ConvertTo-Json
    $newContact = Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/contacts/" -Method Post -Headers $headers -Body $contactBody
    $contactId = $newContact.contact.id
    Write-Host "   ✅ Created new contact with ID: $contactId"
    return $contactId
}

function Get-OrCreateGhlOpportunity {
    param($headers, $pipelineId, $stageId, $contactId, [hashtable]$contact, [PSCustomObject]$leadData)
    $oppTitle = "$($contact.firstName) - $($contact.company)"
    Write-Host " OPPORTUNITY: Getting or creating GHL opportunity: $oppTitle"
    
    $opps = (Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/pipelines/$pipelineId/opportunities?contact_id=$contactId" -Method Get -Headers $headers).opportunities
    $existingOpp = $opps | Where-Object { $_.title -eq $oppTitle }

    if ($existingOpp) {
        Write-Host "   ✅ Found existing opportunity."
        return $existingOpp
    }

    Write-Host "   No opportunity found. Creating..."
    
    # Convert the full lead data to JSON for the description
    $fullLeadDataJson = $leadData | ConvertTo-Json -Depth 10
    
    $oppBody = @{
        pipelineId = $pipelineId
        stageId    = $stageId
        title      = $oppTitle
        status     = "open"
        contactId  = $contactId
        description = "Full Lead Data: $fullLeadDataJson"
    } | ConvertTo-Json
    $newOpp = Invoke-RestMethod -Uri "https://rest.gohighlevel.com/v1/pipelines/$pipelineId/opportunities" -Method Post -Headers $headers -Body $oppBody
    Write-Host "   ✅ Created new opportunity with full lead data."
    return $newOpp
}

function Get-OrCreateGitHubRepository {
    param($headers, [hashtable]$contact)
    $cleanName = ($contact.company -replace '[^a-zA-Z0-9]', '').ToLower()
    $repoName = "sa-$cleanName"
    Write-Host "📦 Getting or creating GitHub repository: $repoName"

    try {
        $existingRepo = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName" -Headers $headers -ErrorAction Stop
        Write-Host "   ✅ Found existing repository."
        return $existingRepo
    }
    catch {
        Write-Host "   No repository found. Creating from template..."
        $repoBody = @{ name = $repoName; private = $true } | ConvertTo-Json
        $newRepo = Invoke-RestMethod -Method POST -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$($settings.TemplateRepo)/generate" -Headers $headers -Body $repoBody -ContentType "application/json"
        Write-Host "   ✅ Created new repository: $($newRepo.html_url)"
        
        # Wait a moment for the repository to be fully created
        Start-Sleep -Seconds 3
        
        # Step 2: Delete existing workflows (using file-based deletion)
        Write-Host "   🗑️ Deleting existing workflows..."
        try {
            $workflows = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/actions/workflows" -Headers $headers -ErrorAction Stop
            foreach ($workflow in $workflows.workflows) {
                Write-Host "     Deleting workflow: $($workflow.name)"
                try {
                    # First, get the actual workflow file details
                    $workflowsDirUrl = "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/contents/.github/workflows"
                    $workflowFiles = Invoke-RestMethod -Method GET -Uri $workflowsDirUrl -Headers $headers -ErrorAction Stop
                    
                    # Find the workflow file (there should only be one)
                    if ($workflowFiles.Count -gt 0) {
                        $workflowFile = $workflowFiles[0]
                        $workflowPath = ".github/workflows/$($workflowFile.name)"
                        
                        $deleteBody = @{
                            message = "Remove workflow: $($workflow.name)"
                            sha = $workflowFile.sha
                        } | ConvertTo-Json
                        
                        Invoke-RestMethod -Method DELETE -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/contents/$workflowPath" -Headers $headers -Body $deleteBody -ContentType "application/json" -ErrorAction Stop
                        Write-Host "       ✅ Deleted workflow file: $($workflowFile.name)"
                    } else {
                        throw "No workflow files found"
                    }
                }
                catch {
                    Write-Host "       ⚠️ Could not delete workflow file: $($_.Exception.Message)"
                    # Fallback: try to disable the workflow instead
                    try {
                        $disableBody = @{ state = "disabled" } | ConvertTo-Json
                        Invoke-RestMethod -Method PATCH -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/actions/workflows/$($workflow.id)" -Headers $headers -Body $disableBody -ContentType "application/json" -ErrorAction Stop
                        Write-Host "       ✅ Disabled workflow instead"
                    }
                    catch {
                        Write-Host "       ❌ Could not disable workflow either: $($_.Exception.Message)"
                    }
                }
            }
            Write-Host "   ✅ Workflow cleanup completed"
        }
        catch {
            Write-Warning "   ⚠️ Could not access workflows: $($_.Exception.Message)"
        }
        
        # After workflow cleanup, perform directory rename
        $defaultBranch = if ($newRepo.default_branch) { $newRepo.default_branch } else { "main" }
        Write-Host "   Waiting for sa-template directory to be available..."
        $wait = 0
        $maxWait = 60  # seconds
        $templateReady = $false
        while ($wait -lt $maxWait -and -not $templateReady) {
            try {
                Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/contents/sa-template" -Headers $headers -ErrorAction Stop | Out-Null
                $templateReady = $true
                Write-Host "   ✅ sa-template directory is ready"
            }
            catch {
                Start-Sleep -Seconds 3
                $wait += 3
                Write-Host "   ⏳ Waiting for template... ($wait/$maxWait seconds)"
            }
        }

        if (-not $templateReady) {
            throw "sa-template directory not available after $maxWait seconds"
        }

        Write-Host "   Renaming sa-template directory to $repoName via Git data API..."
        Rename-GitHubDirectory -org $settings.GitHubOrg -repo $repoName -oldPath "sa-template" -newPath $repoName -headers $headers -branch $defaultBranch
        Write-Host "   ✅ Directory renamed successfully"
        
        # Step 4: Set up branch protection for main branch
        Write-Host "   🔒 Setting up branch protection for main branch..."
        try {
            # Try minimal protection first
            $protectionBody = @{
                required_pull_request_reviews = @{
                    required_approving_review_count = 1
                    dismiss_stale_reviews = $true
                }
                allow_force_pushes = $false
                allow_deletions = $false
            } | ConvertTo-Json -Depth 10
            
            Invoke-RestMethod -Method PUT -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repoName/branches/main/protection" -Headers $headers -Body $protectionBody -ContentType "application/json" -ErrorAction Stop
            Write-Host "   ✅ Successfully set up branch protection for main branch"
        }
        catch {
            Write-Warning "   ⚠️ Could not set up branch protection: $($_.Exception.Message)"
            Write-Host "   ℹ️ This may require admin permissions on the repository" -ForegroundColor Yellow
            Write-Host "   ℹ️ Branch protection can be set up manually in GitHub web interface" -ForegroundColor Yellow
        }
        
        return $newRepo
    }
}

function Get-OrCreateAzureResourceGroup {
    param($rgName, $location)
    Write-Host "📦 Getting or creating Azure Resource Group: $rgName"
    $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Host "   ✅ Found existing resource group."
        return $rg
    }
    Write-Host "   No resource group found. Creating..."
    $newRg = New-AzResourceGroup -Name $rgName -Location $location
    Write-Host "   ✅ Created new resource group."
    return $newRg
}

function Get-OrCreateSharedBlobStorage {
    param($rgName, $location, $storageName, $sku)
    Write-Host "📦 Getting or creating shared Azure Storage Account: $storageName"
    $storage = Get-AzStorageAccount -ResourceGroupName $rgName -Name $storageName -ErrorAction SilentlyContinue
    if ($storage) {
        Write-Host "   ✅ Found existing Storage Account."
    } else {
        Write-Host "   No Storage Account found. Creating..."
        $storage = New-AzStorageAccount -ResourceGroupName $rgName -Name $storageName -Location $location -SkuName $sku -Kind StorageV2
        Set-AzStorageAccount -ResourceGroupName $rgName -Name $storageName -EnableHttpsTrafficOnly $true
        Enable-AzStorageStaticWebsite -Context $storage.Context -IndexDocument "index.html" -ErrorDocument404Path "404.html"
        Write-Host "   ✅ Created new Storage Account with static website enabled."
    }
    $webEndpoint = $storage.PrimaryEndpoints.Web
    Write-Host "   🌐 Web URL: $webEndpoint"
    return @{ Storage = $storage; WebEndpoint = $webEndpoint }
}

function Get-OrCreateFrontDoor {
    param($rgName, $location, $profileName)
    Write-Host "📦 Getting or creating Azure Front Door profile: $profileName"
    $profile = Get-AzFrontDoorCdnProfile -ResourceGroupName $rgName -ProfileName $profileName -ErrorAction SilentlyContinue
    if ($profile) {
        Write-Host "   ✅ Found existing Front Door profile."
    } else {
        Write-Host "   No Front Door profile found. Creating Standard profile..."
        $profile = New-AzFrontDoorCdnProfile -ResourceGroupName $rgName -ProfileName $profileName -Location Global -SkuName Standard_AzureFrontDoor
        Write-Host "   ✅ Created new Front Door profile."
    }

    # Get or create endpoint (default one)
    $endpointName = "$profileName-endpoint"
    $endpoint = Get-AzFrontDoorCdnEndpoint -ResourceGroupName $rgName -ProfileName $profileName -EndpointName $endpointName -ErrorAction SilentlyContinue
    if (-not $endpoint) {
        $endpoint = New-AzFrontDoorCdnEndpoint -ResourceGroupName $rgName -ProfileName $profileName -EndpointName $endpointName -Location Global
    }

    # Get or create origin group and origin for prod storage
    $prodStorage = Get-AzStorageAccount -ResourceGroupName $rgName -Name $settings.ProdStorageAccount
    $originGroupName = "prod-origin-group"
    $originGroup = Get-AzFrontDoorCdnOriginGroup -ResourceGroupName $rgName -ProfileName $profileName -OriginGroupName $originGroupName -ErrorAction SilentlyContinue
    if (-not $originGroup) {
        $originGroup = New-AzFrontDoorCdnOriginGroup -ResourceGroupName $rgName -ProfileName $profileName -OriginGroupName $originGroupName -LoadBalancingAdditionalLatencyInMilliseconds 0 -LoadBalancingSampleSize 4 -LoadBalancingSuccessfulSamplesRequired 3
    }

    $originName = "prod-storage-origin"
    $origin = Get-AzFrontDoorCdnOrigin -ResourceGroupName $rgName -ProfileName $profileName -OriginGroupName $originGroupName -OriginName $originName -ErrorAction SilentlyContinue
    if (-not $origin) {
        $hostName = $prodStorage.PrimaryEndpoints.Web.Replace("https://", "").Replace("/", "")
        $origin = New-AzFrontDoorCdnOrigin -ResourceGroupName $rgName -ProfileName $profileName -OriginGroupName $originGroupName -OriginName $originName -HostName $hostName -OriginHostHeader $hostName -Priority 1 -Weight 1000 -Enabled
    }

    return @{ Profile = $profile; EndpointName = $endpointName; OriginGroupId = $originGroup.Id }
}

function AddFrontDoorRoute {
    param($rgName, $profileName, $endpointName, $originGroupId, $cleanName)
    Write-Host "Adding Front Door route for path /$cleanName/*"
    $routeName = "route$cleanName"  # Removed hyphen
    $route = Get-AzFrontDoorCdnRoute -ResourceGroupName $rgName -ProfileName $profileName -EndpointName $endpointName -Name $routeName -ErrorAction SilentlyContinue
    if ($route) {
        Write-Host "   ✅ Route already exists."
    } else {
        $ruleSetName = "ruleset$cleanName"  # Removed hyphen
        $ruleSet = Get-AzFrontDoorCdnRuleSet -ResourceGroupName $rgName -ProfileName $profileName -Name $ruleSetName -ErrorAction SilentlyContinue
        if (-not $ruleSet) {
            $ruleSet = New-AzFrontDoorCdnRuleSet -ResourceGroupName $rgName -ProfileName $profileName -Name $ruleSetName
        }

        $ruleName = "rewrite$cleanName"  # Removed hyphen
        $rule = Get-AzFrontDoorCdnRule -ResourceGroupName $rgName -ProfileName $profileName -RuleSetName $ruleSetName -Name $ruleName -ErrorAction SilentlyContinue
        if (-not $rule) {
            # Rewrite /<site>/* to /prod-sa-<site>/* (preserving anything after the site prefix).
            $condition = New-AzFrontDoorCdnRuleUrlPathConditionObject -Name "UrlPath" -ParameterOperator "BeginsWith" -ParameterMatchValue "/$cleanName/"
            $action = New-AzFrontDoorCdnRuleUrlRewriteActionObject -Name "UrlRewrite" -ParameterSourcePattern "/$cleanName/" -ParameterDestination "/prod-sa-$cleanName/" -ParameterPreserveUnmatchedPath $true
            $rule = New-AzFrontDoorCdnRule -ResourceGroupName $rgName -ProfileName $profileName -RuleSetName $ruleSetName -Name $ruleName -Action $action -Condition $condition -Order 1 -MatchProcessingBehavior "Stop"
        }

        $patterns = @("/$cleanName", "/$cleanName/*")
        $ruleSetReference = New-AzFrontDoorCdnResourceReferenceObject -Id $ruleSet.Id
        $route = New-AzFrontDoorCdnRoute -ResourceGroupName $rgName -ProfileName $profileName -EndpointName $endpointName -Name $routeName -OriginGroupId $originGroupId -PatternsToMatch $patterns -ForwardingProtocol HttpsOnly -LinkToDefaultDomain Enabled -HttpsRedirect Enabled -RuleSet $ruleSetReference
        Write-Host "   ✅ Added route."
    }
    # Return the Front Door URL with a trailing slash so users hit a working route directly
    return "https://$endpointName.azurefd.net/$cleanName/"
}

function Generate-WebsitePrompt {
    param($headers, [PSCustomObject]$leadData, [string]$repoName)
    Write-Host "🤖 Generating website prompt with OpenAI..."
    
    $prompt = @"
Create a detailed prompt for a web development AI to generate a complete website based on this info:
- Business Name: $($leadData.lead.businessName)
- Contact: $($leadData.lead.contactName)
- Description: $($leadData.websiteRequirements.businessDescription)
- Pages Requested: $($leadData.pageRequirements.requestedPages -join ", ")
- Websites they like: $($leadData.websiteRequirements.otherWebsitesLike)
- Additional notes: $($leadData.projectDetails.additionalNotes)

IMPORTANT: The website content should be placed in the '$repoName' subdirectory of the repository root.
"@
    
    $body = @{
        model    = $settings.OpenAIModel
        messages = @(@{ role = "user"; content = $prompt })
        max_tokens = 2000
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -Body $body -ErrorAction Stop
        $websitePrompt = $response.choices[0].message.content
        Write-Host "   ✅ OpenAI prompt generated successfully."
        return $websitePrompt
    }
    catch {
        Write-Warning "   ❌ OpenAI prompt generation failed: $($_.Exception.Message)"
        Write-Host "   Falling back to basic prompt..."
        return "Create a professional website for $($leadData.lead.businessName). It is a $($leadData.websiteRequirements.businessDescription). IMPORTANT: Place all website content in the '$repoNameTrimmed' subdirectory of the repository root."
    }
}

function Send-SummaryEmail {
    param([hashtable]$results)
    Write-Host "📧 Sending summary email..."
    # Ensure repository URLs are clean
    $repoHtmlUrl  = ([string]$results.gitHubRepo.html_url).Trim()
    $repoCloneUrl = ([string]$results.gitHubRepo.clone_url).Trim()
    $subject = "✅ New Lead Setup Complete - $($results.contact.company)"
    
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background-color: #f8f9fa; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .section { margin-bottom: 25px; }
        .section h3 { color: #007bff; border-bottom: 2px solid #007bff; padding-bottom: 5px; }
        .link { color: #007bff; text-decoration: none; }
        .link:hover { text-decoration: underline; }
        .success { color: #28a745; font-weight: bold; }
        .info { background-color: #e7f3ff; padding: 15px; border-radius: 5px; margin: 10px 0; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🎉 New Lead Setup Complete</h2>
            <p><strong>Client:</strong> $($results.contact.firstName) $($results.contact.company)</p>
            <p><strong>Email:</strong> $($results.contact.email)</p>
            <p><strong>Phone:</strong> $($results.contact.phone)</p>
            <p><strong>Date:</strong> $(Get-Date -Format 'MMMM dd, yyyy HH:mm')</p>
        </div>

        <div class="section">
            <h3>📋 GoHighLevel CRM</h3>
            <div class="info">
                <p><strong>Contact Created/Updated:</strong> ✅</p>
                <p><strong>Opportunity Created:</strong> $($results.opportunity.title)</p>
                <p><strong>Opportunity ID:</strong> $($results.opportunity.id)</p>
                <p><strong>Pipeline:</strong> Leads</p>
                <p><strong>Stage:</strong> New Leads</p>
                <p><a href="$($settings.GhlDomain)/v2/location/$($settings.GhlLocationId)/contacts/detail/$($results.contactId)" class="link">View Contact in GoHighLevel →</a></p>
                <p><a href="$($settings.GhlDomain)/v2/location/$($settings.GhlLocationId)/opportunities/list/$($results.opportunity.id)?tab=Opportunity%20Details" class="link">View Opportunity in GoHighLevel →</a></p>
            </div>
        </div>

        <div class="section">
            <h3>📁 GitHub Repository</h3>
            <div class="info">
                <p><strong>Repository Name:</strong> $repoNameTrimmed</p>
                <p><strong>Repository URL:</strong> <a href="$repoHtmlUrl" class="link">$repoHtmlUrl</a></p>
                <p><strong>Clone URL:</strong> <a href="$repoCloneUrl" class="link">$repoCloneUrl</a></p>
                <p><strong>Visibility:</strong> $(if ($results.gitHubRepo.private) { 'Private' } else { 'Public' })</p>
                <p><strong>Branch Structure:</strong> main (production) ← master (development)</p>
                <p><strong>Workflows:</strong> Cleaned up template workflows; added deploy-test.yml for master; added deploy-prod.yml for main</p>
                <p><strong>Branch Protection:</strong> Applied to main</p>
                <p><strong>Subdirectory:</strong> $repoNameTrimmed (created)</p>
                <p><a href="$repoHtmlUrl" class="link">Open Repository →</a></p>
                <p><a href="$repoHtmlUrl/tree/master" class="link">View Master Branch →</a></p>
            </div>
        </div>

        <div class="section">
            <h3>🌐 Prod Site (Blob Storage + Front Door)</h3>
            <div class="info">
                <p><strong>Storage Account:</strong> $($settings.ProdStorageAccount)</p>
                <p><strong>Subfolder:</strong> prod-$repoNameTrimmed</p>
                <p><strong>Live URL:</strong> <a href="$($results.frontDoorUrl)" class="link">$($results.frontDoorUrl)</a></p>
                <p><strong>Status:</strong> <span class="success">✅ Deployed from main</span></p>
                <p><strong>Deployment:</strong> Automatic on push to main via GitHub Actions</p>
                <p><strong>Workflow:</strong> deploy-prod.yml (adjust if build command differs)</p>
                <p><strong>Configuration:</strong></p>
                <ul>
                    <li><strong>Geo-Redundancy:</strong> GZRS</li>
                    <li><strong>Front Door Path:</strong> /$repoNameTrimmed/* rewrites to /prod$repoNameTrimmed/{*}</li>
                </ul>
                <p><a href="$($results.frontDoorUrl)" class="link">Visit Live Site →</a></p>
            </div>
        </div>

        <div class="section">
            <h3>🧪 Test Site (Blob Storage)</h3>
            <div class="info">
                <p><strong>Storage Account:</strong> $($settings.TestStorageAccount)</p>
                <p><strong>Subfolder:</strong> test-$repoNameTrimmed</p>
                <p><strong>Test URL:</strong> <a href="$($results.blobStorage.WebEndpoint)test-$repoNameTrimmed/" class="link">$($results.blobStorage.WebEndpoint)test-$($results.gitHubRepo.name)/</a></p>
                <p><strong>Deployment:</strong> Automatic on push to master via GitHub Actions</p>
                <p><strong>Workflow:</strong> deploy-test.yml (adjust if build command differs)</p>
                <p><a href="$($results.blobStorage.WebEndpoint)test-$repoNameTrimmed/" class="link">Visit Test Site →</a></p>
            </div>
        </div>

        <div class="section">
            <h3>🤖 Same.New Website Generation Prompt</h3>
            <div class="info" style="background-color: #f0f8ff;">
                <p><strong>Instructions for Same.New:</strong></p>
                <p style="margin-bottom: 15px;"><strong>First, clone the repository:</strong></p>
                <div style="background-color: #2d2d2d; color: #f8f8f2; padding: 15px; border-radius: 5px; font-family: 'Courier New', monospace; font-size: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-all;">git clone --branch master https://$($settings.GitHubToken)@github.com/$($settings.GitHubOrg)/$repoNameTrimmed.git</div>
                <p style="margin-top: 20px;"><strong>Then use this prompt:</strong></p>
                <pre style="white-space: pre-wrap; font-family: 'Courier New', monospace; font-size: 12px; line-height: 1.4; background-color: #f5f5f5; padding: 15px; border-radius: 5px; overflow-x: auto;">$(($results.websitePrompt) -replace '<', '<' -replace '>', '>')</pre>
                <p style="margin-top: 15px;"><strong>Next Steps:</strong></p>
                <ol>
                    <li>Clone the repository using the command above</li>
                    <li>Copy the prompt above</li>
                    <li>Go to Same.New</li>
                    <li>Paste the prompt to generate the website</li>
                    <li>Review and customize the generated code</li>
                    <li>Push the final code to the master branch (triggers test deploy to blob)</li>
                </ol>
                <p style="margin-top: 15px;"><strong>Force Update Command for push from Same.New. Run in terminal:</strong></p>
                <div style="background-color: #2d2d2d; color: #f8f8f2; padding: 15px; border-radius: 5px; font-family: 'Courier New', monospace; font-size: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-all;">[ "`$(basename "`$PWD")" = "$repoNameTrimmed" ] && cd .. ; rm -rf .git && git init && git remote add origin https://$($settings.GitHubToken)@github.com/$($settings.GitHubOrg)/$repoNameTrimmed.git && git add . && git commit -m "Force update" && git push --force origin master</div>
                <p style="margin-top: 10px; font-size: 11px; color: #666;"><em>This command reinitializes the git repository and force pushes to master. Use with caution as it will overwrite the remote repository.</em></p>
                <p style="margin-top: 15px;"><strong>7. Create a pull request from master to main when ready to deploy to production</strong></p>
            </div>
        </div>

        <div class="section">
            <h3>🔗 Quick Links</h3>
            <div class="info">
                <p><a href="https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupPrd)/providers/Microsoft.Cdn/profiles/$($settings.FrontDoorProfileName)" class="link">Azure Portal - Front Door →</a></p>
                <p><a href="https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupPrd)/providers/Microsoft.Storage/storageAccounts/$($settings.ProdStorageAccount)" class="link">Azure Portal - Prod Blob Storage →</a></p>
                <p><a href="https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupUat)/providers/Microsoft.Storage/storageAccounts/$($settings.TestStorageAccount)" class="link">Azure Portal - Test Blob Storage →</a></p>
                <p><a href="https://github.com/$($settings.GitHubOrg)/$repoNameTrimmed/actions" class="link">GitHub Actions →</a></p>
                <p><a href="$($settings.GhlDomain)/v2/location/$($settings.GhlLocationId)/opportunities/list" class="link">GoHighLevel Pipeline →</a></p>
            </div>
        </div>

        <div class="footer">
            <p>This email was automatically generated by the NowSites Setup Script.</p>
            <p>Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')</p>
        </div>
    </div>
</body>
</html>
"@

    $textContent = @"
New Lead Setup Complete

Client: $($results.contact.firstName) $($results.contact.company)
Email: $($results.contact.email)
Phone: $($results.contact.phone)
Date: $(Get-Date -Format 'MMMM dd, yyyy HH:mm')

GoHighLevel CRM:
- Contact Created/Updated: ✅
- Opportunity Created: $($results.opportunity.title)
- Opportunity ID: $($results.opportunity.id)
- Pipeline: Leads
- Stage: New Leads
- View Contact: $($settings.GhlDomain)/v2/location/$($settings.GhlLocationId)/contacts/detail/$($results.contactId)
- View Opportunity: $($settings.GhlDomain)/v2/location/$($settings.GhlLocationId)/opportunities/list/$($results.opportunity.id)?tab=Opportunity%20Details

GitHub Repository:
- Repository Name: $repoNameTrimmed
- Repository URL: $repoHtmlUrl
- Clone URL: $repoCloneUrl
- Visibility: $(if ($results.gitHubRepo.private) { 'Private' } else { 'Public' })
- Branch Structure: main (production) ← master (development)
- Workflows: Cleaned up template workflows; added deploy-test.yml for master; added deploy-prod.yml for main
- Branch Protection: Applied to main
- Subdirectory: $repoNameTrimmed (created)

Prod Site (Blob Storage + Front Door):
- Storage Account: $($settings.ProdStorageAccount)
- Subfolder: prod-$repoNameTrimmed
- Live URL: $($results.frontDoorUrl)
- Status: ✅ Deployed from main
- Deployment: Automatic on push to main via GitHub Actions
- Workflow: deploy-prod.yml (adjust if build command differs)
- Configuration:
  * Geo-Redundancy: GZRS
  * Front Door Path: /$repoNameTrimmed/* rewrites to /prod-$repoNameTrimmed/{*}

Test Site (Blob Storage):
- Storage Account: $($settings.TestStorageAccount)
- Subfolder: test-$repoNameTrimmed
- Test URL: $($results.blobStorage.WebEndpoint)test-$repoNameTrimmed/
- Deployment: Automatic on push to master via GitHub Actions
- Workflow: deploy-test.yml (adjust if build command differs)

Same.New Website Generation Instructions:
=====================================

First, clone the repository:
git clone --branch master https://$($settings.GitHubToken)@github.com/$($settings.GitHubOrg)/$repoNameTrimmed.git

Then use this prompt:
$($results.websitePrompt)

Next Steps:
1. Clone the repository using the command above
2. Copy the prompt above
3. Go to Same.New
4. Paste the prompt to generate the website
5. Review and customize the generated code
6. Push the final code to the master branch (triggers test deploy to blob)


Force Update Command for push from Same.New. Run in terminal:
[ "`$(basename "`$PWD")" = "$repoNameTrimmed" ] && cd .. ; rm -rf .git && git init && git remote add origin https://$($settings.GitHubToken)@github.com/$($settings.GitHubOrg)/$repoNameTrimmed.git && git add . && git commit -m "Force update" && git push --force origin master

This command reinitializes the git repository and force pushes to master. Use with caution as it will overwrite the remote repository.

6. Create a pull request from master to main when ready to deploy to production
Quick Links:
- Azure Portal - Front Door: https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupPrd)/providers/Microsoft.Cdn/profiles/$($settings.FrontDoorProfileName)
- Azure Portal - Prod Blob Storage: https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupPrd)/providers/Microsoft.Storage/storageAccounts/$($settings.ProdStorageAccount)
- Azure Portal - Test Blob Storage: https://portal.azure.com/#@/resource/subscriptions/$($settings.AzureSubscriptionId)/resourceGroups/$($settings.AzureResourceGroupUat)/providers/Microsoft.Storage/storageAccounts/$($settings.TestStorageAccount)
- GitHub Actions: https://github.com/$($settings.GitHubOrg)/$repoNameTrimmed/actions
- GoHighLevel Pipeline: $($settings.GhlDomain)/v2/location/$repoNameTrimmed/opportunities

---
This email was automatically generated by the NowSites Setup Script.
Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')
"@

    $emailBody = @{
        personalizations = @(@{ to = @(@{ email = $settings.EmailTo }) })
        from             = @{ email = $settings.EmailFrom }
        subject          = $subject
        content          = @(
            @{ type = "text/plain"; value = $textContent },
            @{ type = "text/html"; value = $htmlContent }
        )
        tracking_settings = @{
            click_tracking = @{ enable = $false }
            open_tracking = @{ enable = $false }
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://api.sendgrid.com/v3/mail/send" -Method Post -Headers $sendGridHeaders -Body $emailBody -ErrorAction Stop
        Write-Host "✅ Summary email sent successfully."
    }
    catch {
        Write-Warning "❌ Failed to send summary email: $($_.Exception.Message)"
    }
}


# --- Main Execution ---

$response = [HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers = @{ "Content-Type" = "application/json" }
}

try {
    Write-Host "▶️ Starting lead processing..."
    $leadData = $Request.Body
    if (-not $leadData) { throw "Request body is empty." }

    # Log the complete submission to host for debugging
    Write-Host "📋 Complete submission received:"
    Write-Host ($leadData | ConvertTo-Json -Depth 10)
    Write-Host "====================================="

    $contactInfo = @{
        firstName = $leadData.lead.contactName
        email     = $leadData.lead.email
        phone     = $leadData.lead.phone
        company   = $leadData.lead.businessName
    }

    $results = @{ }

    # Step 1: Send raw JSON to admin@datan8.com
    Send-RawJsonEmail -leadData $leadData
    
    # Step 2: Send confirmation email to lead
    Send-LeadConfirmationEmail -leadEmail $contactInfo.email -leadName $contactInfo.firstName -leadData $leadData
    
    # Step 3: GHL CRM setup (with error handling)
    try {
        Write-Host "📋 Setting up GoHighLevel CRM..."
        $pipelineInfo = Get-OrCreateGhlPipeline -headers $ghlHeaders
        $results.contactId = Get-OrCreateGhlContact -headers $ghlHeaders -contact $contactInfo
        $results.opportunity = Get-OrCreateGhlOpportunity -headers $ghlHeaders -pipelineId $pipelineInfo.PipelineId -stageId $pipelineInfo.StageId -contactId $results.contactId -contact $contactInfo -leadData $leadData
        Write-Host "✅ GoHighLevel CRM setup completed successfully"
    }
    catch {
        Write-Warning "❌ GoHighLevel CRM setup failed: $($_.Exception.Message)"
        Write-Host "Continuing with other steps..."
        $results.ghlError = $_.Exception.Message
    }

    # Step 4: GitHub and Azure
    $results.gitHubRepo = Get-OrCreateGitHubRepository -headers $gitHubHeaders -contact $contactInfo
    $rgPrd = Get-OrCreateAzureResourceGroup -rgName $settings.AzureResourceGroupPrd -location $settings.AzureLocation
    $rgUat = Get-OrCreateAzureResourceGroup -rgName $settings.AzureResourceGroupUat -location $settings.AzureLocation
    $cleanCompanyName = ($contactInfo.company -replace '[^a-zA-Z0-9]', '').ToLower()

    # Get shared test and prod storage
    $results.blobStorage = Get-OrCreateSharedBlobStorage -rgName $rgUat.ResourceGroupName -location $rgUat.Location -storageName $settings.TestStorageAccount -sku "Standard_LRS"
    $prodBlob = Get-OrCreateSharedBlobStorage -rgName $rgPrd.ResourceGroupName -location $rgPrd.Location -storageName $settings.ProdStorageAccount -sku "Standard_LRS"

    # Get or create Front Door for prod
    $fd = Get-OrCreateFrontDoor -rgName $rgPrd.ResourceGroupName -location $rgPrd.Location -profileName $settings.FrontDoorProfileName
    $results.frontDoorUrl = AddFrontDoorRoute -rgName $rgPrd.ResourceGroupName -profileName $settings.FrontDoorProfileName -endpointName "$($settings.FrontDoorProfileName)-endpoint" -originGroupId $fd.OriginGroupId -cleanName $cleanCompanyName

    # Wait for repo to be ready
    Start-Sleep -Seconds 30

    # Create master branch from main
    Write-Host "   🌿 Creating master branch from main (with retries)..."

    $maxBranchAttempts = 10
    $branchAttempt     = 0
    $mainBranch        = $null

    $orgNameTrimmed  = ([string]$settings.GitHubOrg).Trim()
    $repoNameTrimmed = ([string]$results.gitHubRepo.name).Trim()

    while (-not $mainBranch -and $branchAttempt -lt $maxBranchAttempts) {
        try {
            $testUri = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/branches/main"
            $mainBranch = Invoke-RestMethod -Method GET -Uri $testUri -Headers $gitHubHeaders -ErrorAction Stop
            Write-Host "      ✅ Found main branch SHA $($mainBranch.commit.sha)"
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                $branchAttempt++
                Write-Host "      ⏳ Main branch not ready yet (attempt $branchAttempt/$maxBranchAttempts). Waiting 3s..."
                Start-Sleep -Seconds 30
            }
            else { throw }
        }
    }

    if (-not $mainBranch) {
        Write-Warning "      ❌ Main branch still not found after $maxBranchAttempts attempts. Skipping master branch creation."
    }
    else {
        $branchUrl = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/git/refs"
        $createBranchBodyObj = @{ ref = "refs/heads/master"; sha = $mainBranch.commit.sha }
        $createBranchBodyJson = $createBranchBodyObj | ConvertTo-Json

        Write-Host "      📤 Branch creation POST -> $branchUrl"
        Write-Host "      📤 Body:`n$createBranchBodyJson"

        try {
            Invoke-RestMethod -Method POST -Uri $branchUrl -Headers $gitHubHeaders -Body $createBranchBodyJson -ContentType "application/json" -ErrorAction Stop
            Write-Host "      ✅ Successfully created master branch from main"
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 422) {
                Write-Host "      ℹ️  Master branch already exists – continuing."
            }
            else {
                Write-Warning "      ⚠️  Could not create master branch: $($_.Exception.Message)"
            }
        }
    }

    # Set up OIDC for test storage with improved error handling and timing
    Write-Host "   🔐 Setting up OIDC for test storage..."
    Write-Host "     🔍 results.gitHubRepo.name: $($results.gitHubRepo.name)"

    $appNameOidcTest = "GH-Deploy-$repoNameTrimmed-Test"
    Write-Host "     🔍 appNameOidcTest: $appNameOidcTest"
    # Check if app already exists
    $existingAppTest = Get-AzADApplication -DisplayName $appNameOidcTest -ErrorAction SilentlyContinue
    if ($existingAppTest) {
        Write-Host "     ✅ Found existing app: $appNameOidcTest"
        $appTest = $existingAppTest
    } else {
        Write-Host "     📝 Creating new app: $appNameOidcTest"
        $appTest = New-AzADApplication -DisplayName $appNameOidcTest -SignInAudience AzureADMyOrg
    }
    
    $appIdTest = $appTest.AppId
    $appObjectIdTest = $appTest.Id
    $tenantId = (Get-AzTenant).Id
    $subId = $settings.AzureSubscriptionId
    
    # Create federated credential with more specific subject
    $subjectTest = "repo:$($orgNameTrimmed.ToLower())/$($repoNameTrimmed.ToLower()):ref:refs/heads/master"
    Write-Host "     🔍 Debugging federated credential subject creation:"
    Write-Host "       Original settings.GitHubOrg: '$($settings.GitHubOrg)'"
    Write-Host "       orgNameTrimmed: '$orgNameTrimmed'"
    Write-Host "       orgNameTrimmed.ToLower(): '$($orgNameTrimmed.ToLower())'"
    Write-Host "       repoNameTrimmed: '$repoNameTrimmed'"
    Write-Host "       repoNameTrimmed.ToLower(): '$($repoNameTrimmed.ToLower())'"
    Write-Host "       Final subjectTest: '$subjectTest'"
    $credentialCreated = Get-OrCreateFederatedCredential -ApplicationObjectId $appObjectIdTest -Name "MasterBranch" -Subject $subjectTest
    if (-not $credentialCreated) {
        throw "Failed to create or find federated credential for test"
    }
    
    # Wait longer for propagation
    Write-Host "     ⏳ Waiting for Azure AD propagation..."
    Start-Sleep -Seconds 30
    
    # Ensure service principal exists
    $spTest = Get-AzADServicePrincipal -ApplicationId $appTest.AppId -ErrorAction SilentlyContinue
    if (-not $spTest) {
        Write-Host "     👤 Creating service principal for test"
        $spTest = New-AzADServicePrincipal -ApplicationId $appTest.AppId
        Start-Sleep -Seconds 120  # Increased to 2 minutes for propagation
    }

    # Assign role with retry loop
    $maxRetries = 3
    $retryCount = 0
    $roleAssigned = $false
    while (-not $roleAssigned -and $retryCount -lt $maxRetries) {
        try {
            New-AzRoleAssignment -ObjectId $spTest.Id -RoleDefinitionName "Storage Blob Data Contributor" -Scope $results.blobStorage.Storage.Id -ErrorAction Stop
            Write-Host "     ✅ Role assigned for test storage"
            $roleAssigned = $true
        } catch {
            if ($_.Exception.Message -match "already exists") {
                Write-Host "     ℹ️ Role assignment already exists"
                $roleAssigned = $true
            } else {
                Write-Warning "     ⚠️ Role assignment attempt $($retryCount + 1) failed: $($_.Exception.Message)"
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 60  # Wait 1 minute before retry
                }
            }
        }
    }
    if (-not $roleAssigned) {
        throw "Failed to assign role after $maxRetries attempts"
    }

    # Set up OIDC for prod storage with improved error handling and timing
    Write-Host "   🔐 Setting up OIDC for prod storage..."
    $appNameOidcProd = "GH-Deploy-$repoNameTrimmed-Prod"
    
    # Check if app already exists
    $existingAppProd = Get-AzADApplication -DisplayName $appNameOidcProd -ErrorAction SilentlyContinue
    if ($existingAppProd) {
        Write-Host "     ✅ Found existing app: $appNameOidcProd"
        $appProd = $existingAppProd
    } else {
        Write-Host "     📝 Creating new app: $appNameOidcProd"
        $appProd = New-AzADApplication -DisplayName $appNameOidcProd -SignInAudience AzureADMyOrg
    }
    
    $appIdProd = $appProd.AppId
    $appObjectIdProd = $appProd.Id
    
    # Create federated credential with more specific subject
    $subjectProd = "repo:$($orgNameTrimmed.ToLower())/$($repoNameTrimmed.ToLower()):ref:refs/heads/main"
    $credentialCreated = Get-OrCreateFederatedCredential -ApplicationObjectId $appObjectIdProd -Name "MainBranch" -Subject $subjectProd
    if (-not $credentialCreated) {
        throw "Failed to create or find federated credential for prod"
    }
    
    # Wait longer for propagation
    Write-Host "     ⏳ Waiting for Azure AD propagation..."
    Start-Sleep -Seconds 30
    
    # Ensure service principal exists
    $spProd = Get-AzADServicePrincipal -ApplicationId $appProd.AppId -ErrorAction SilentlyContinue
    if (-not $spProd) {
        Write-Host "     👤 Creating service principal for prod"
        $spProd = New-AzADServicePrincipal -ApplicationId $appProd.AppId
        Start-Sleep -Seconds 120  # Increased to 2 minutes for propagation
    }

    # Assign role with retry loop
    $maxRetries = 3
    $retryCount = 0
    $roleAssigned = $false
    while (-not $roleAssigned -and $retryCount -lt $maxRetries) {
        try {
            New-AzRoleAssignment -ObjectId $spProd.Id -RoleDefinitionName "Storage Blob Data Contributor" -Scope $prodBlob.Storage.Id -ErrorAction Stop
            Write-Host "     ✅ Role assigned for prod storage"
            $roleAssigned = $true
        } catch {
            if ($_.Exception.Message -match "already exists") {
                Write-Host "     ℹ️ Role assignment already exists"
                $roleAssigned = $true
            } else {
                Write-Warning "     ⚠️ Role assignment attempt $($retryCount + 1) failed: $($_.Exception.Message)"
                $retryCount++
                if ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 60  # Wait 1 minute before retry
                }
            }
        }
    }
    if (-not $roleAssigned) {
        throw "Failed to assign role after $maxRetries attempts"
    }

    # Verify federated credentials are properly set up
    Write-Host "   🔍 Verifying federated credentials..."
    $allTestCreds = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectIdTest -ErrorAction SilentlyContinue
    $testCred = $allTestCreds | Where-Object { $_.Name -eq "MasterBranch" }
    $allProdCreds = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectIdProd -ErrorAction SilentlyContinue
    $prodCred = $allProdCreds | Where-Object { $_.Name -eq "MainBranch" }
    
    if ($testCred -and $prodCred) {
        Write-Host "     ✅ Both federated credentials verified"
        Write-Host "     📋 Test App ID: $appIdTest"
        Write-Host "     📋 Prod App ID: $appIdProd"
        Write-Host "     📋 Tenant ID: $tenantId"
    } else {
        Write-Warning "     ⚠️ Some federated credentials may not be properly configured"
        if (-not $testCred) { Write-Warning "     ❌ Test credential not found" }
        if (-not $prodCred) { Write-Warning "     ❌ Prod credential not found" }
    }


    # Create GitHub Actions workflow for deploying master to test blob
    $workflowPathTest = ".github/workflows/deploy-test.yml"
    $workflowContentTest = @"
name: Deploy to Test Blob Storage

on:
  push:
    branches:
      - master

permissions:
  id-token: write
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install dependencies
        run: npm ci
        working-directory: $repoNameTrimmed

      - name: Build
        run: npm run build
        working-directory: $repoNameTrimmed
        env:
          VITE_BASE: /test-$repoNameTrimmed/

      - name: Login to Azure
        uses: azure/login@v2
        with:
          client-id: $appIdTest
          tenant-id: $tenantId
          subscription-id: $subId

      - name: Upload to Blob Storage
        run: |
          az storage blob upload-batch \
            --account-name $($settings.TestStorageAccount) \
            --destination '`$web/test-$repoNameTrimmed' \
            --source $repoNameTrimmed/build \
            --overwrite \
            --auth-mode login
"@

    $base64ContentTest = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($workflowContentTest))
    
    $workflowUrlTest = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/contents/$workflowPathTest"
    
    $masterBranchUrl = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/git/refs/heads/master"
    $masterRef = Invoke-RestMethod -Method GET -Uri $masterBranchUrl -Headers $gitHubHeaders -ErrorAction Stop
    $masterSha = $masterRef.object.sha
    
    $masterCommit = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/git/commits/$masterSha" -Headers $gitHubHeaders -ErrorAction Stop
    $masterTreeSha = $masterCommit.tree.sha
    
    try {
        $existingFileTest = Invoke-RestMethod -Uri "$workflowUrlTest?ref=master" -Headers $gitHubHeaders -ErrorAction Stop
        $shaTest = $existingFileTest.sha
    } catch {
        $shaTest = $null
    }
    
    $bodyTest = @{
        message = "Add deploy to test workflow for master branch"
        content = $base64ContentTest
        branch = "master"
    }
    if ($shaTest) {
        $bodyTest.sha = $shaTest
    }
    $bodyJsonTest = $bodyTest | ConvertTo-Json
    try {
        Invoke-RestMethod -Method PUT -Uri $workflowUrlTest -Headers $gitHubHeaders -Body $bodyJsonTest -ContentType "application/json" -ErrorAction Stop
        Write-Host "   ✅ Added deploy-test.yml workflow to master branch"
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 422) {
            Write-Host "   ℹ️ deploy-test.yml already exists or is unchanged (422). Continuing."
        } else {
            throw
        }
    }

    # Create GitHub Actions workflow for deploying main to prod blob
    $workflowPathProd = ".github/workflows/deploy-prod.yml"
    $workflowContentProd = @"
name: Deploy to Prod Blob Storage

on:
  push:
    branches:
      - main

permissions:
  id-token: write
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install dependencies
        run: npm ci
        working-directory: $repoNameTrimmed

      - name: Build
        run: npm run build
        working-directory: $repoNameTrimmed
        env:
          VITE_BASE: /prod-$repoNameTrimmed/

      - name: Login to Azure
        uses: azure/login@v2
        with:
          client-id: $appIdProd
          tenant-id: $tenantId
          subscription-id: $subId

      - name: Upload to Blob Storage
        run: |
          az storage blob upload-batch \
            --account-name $($settings.ProdStorageAccount) \
            --destination '`$web/prod-$repoNameTrimmed' \
            --source $repoNameTrimmed/build \
            --overwrite \
            --auth-mode login
"@

    $base64ContentProd = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($workflowContentProd))
    
    $workflowUrlProd = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/contents/$workflowPathProd"
    
    $mainBranchUrl = "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/git/refs/heads/main"
    $mainRef = Invoke-RestMethod -Method GET -Uri $mainBranchUrl -Headers $gitHubHeaders -ErrorAction Stop
    $mainSha = $mainRef.object.sha
    
    $mainCommit = Invoke-RestMethod -Method GET -Uri "https://api.github.com/repos/$orgNameTrimmed/$repoNameTrimmed/git/commits/$mainSha" -Headers $gitHubHeaders -ErrorAction Stop
    $mainTreeSha = $mainCommit.tree.sha
    
    try {
        $existingFileProd = Invoke-RestMethod -Uri "$workflowUrlProd?ref=main" -Headers $gitHubHeaders -ErrorAction Stop
        $shaProd = $existingFileProd.sha
    } catch {
        $shaProd = $null
    }
    
    $bodyProd = @{
        message = "Add deploy to prod workflow for main branch"
        content = $base64ContentProd
        branch = "main"
    }
    if ($shaProd) {
        $bodyProd.sha = $shaProd
    }
    $bodyJsonProd = $bodyProd | ConvertTo-Json
    try {
        Invoke-RestMethod -Method PUT -Uri $workflowUrlProd -Headers $gitHubHeaders -Body $bodyJsonProd -ContentType "application/json" -ErrorAction Stop
        Write-Host "   ✅ Added deploy-prod.yml workflow to main branch"
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 422) {
            Write-Host "   ℹ️ deploy-prod.yml already exists or is unchanged (422). Continuing."
        } else {
            throw
        }
    }

    # Step 5: OpenAI Prompt
    $results.websitePrompt = Generate-WebsitePrompt -headers $openAIHeaders -leadData $leadData -repoName $results.gitHubRepo.name

    # Step 6: Final summary email
    $results.contact = $contactInfo
    Send-SummaryEmail -results $results

    $response.Body = (@{ success = $true; data = $results } | ConvertTo-Json -Depth 100)
    Write-Host "✅ Lead processing completed successfully!"

}
catch {
    Write-Error "❌ An error occurred during lead processing: $($_.Exception.Message)"
    $response.StatusCode = [HttpStatusCode]::InternalServerError
    $response.Body = (@{ success = $false; error = $_.Exception.message } | ConvertTo-Json)
}

# Return HTTP response
Push-OutputBinding -Name Response -Value $response