# Azure Function for handling client approvals
using namespace System.Net

param($Request, $TriggerMetadata)

# Load environment settings
$settings = @{
    GitHubToken = $env:GITHUB_TOKEN
    GitHubOrg = $env:GITHUB_ORG
    SendGridKey = $env:SENDGRID_API_KEY
    EmailFrom = $env:EMAIL_FROM
}

$gitHubHeaders = @{ 
    "Authorization" = "Bearer $($settings.GitHubToken)"
    "Accept" = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Update-GitHubIssue {
    param($headers, [string]$repository, [string]$approvalToken, [string]$status)
    
    try {
        # Find issue by approval token
        $searchUrl = "https://api.github.com/search/issues?q=repo:$($settings.GitHubOrg)/$repository+$approvalToken+in:body+state:open"
        $searchResult = Invoke-RestMethod -Uri $searchUrl -Method Get -Headers $headers -ErrorAction Stop
        
        if ($searchResult.total_count -gt 0) {
            $issue = $searchResult.items[0]
            $issueNumber = $issue.number
            
            $updateBody = @{}
            
            if ($status -eq "approved") {
                $updateBody.labels = @("amazon-q", "client-request", "approved", "amazon-q-ready")
                
                # Add approval comment
                $commentBody = @{
                    body = "@amazon-q This issue has been approved by the client. Please proceed with implementation.`n`nApproval received on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
                } | ConvertTo-Json
                
                Invoke-RestMethod -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repository/issues/$issueNumber/comments" -Method Post -Headers $headers -Body $commentBody -ContentType "application/json" -ErrorAction Stop
            }
            elseif ($status -eq "rejected") {
                $updateBody.labels = @("amazon-q", "client-request", "rejected", "needs-clarification")
                $updateBody.state = "closed"
            }
            
            $updateJson = $updateBody | ConvertTo-Json -Depth 10
            Invoke-RestMethod -Uri "https://api.github.com/repos/$($settings.GitHubOrg)/$repository/issues/$issueNumber" -Method Patch -Headers $headers -Body $updateJson -ContentType "application/json" -ErrorAction Stop
            
            return $true
        }
    }
    catch {
        Write-Error "Failed to update GitHub issue: $($_.Exception.Message)"
        return $false
    }
    
    return $false
}

# Main execution
$response = [HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers = @{ "Content-Type" = "text/html" }
}

try {
    $approvalToken = $Request.Query.token
    $repository = $Request.Query.repo
    $clientResponse = $Request.Query.response  # "approve" or "reject"
    
    if (-not $approvalToken -or -not $clientResponse -or -not $repository) {
        $response.StatusCode = [HttpStatusCode]::BadRequest
        $response.Body = "<h1>Invalid Request</h1><p>Missing required parameters.</p>"
        Push-OutputBinding -Name Response -Value $response
        return
    }
    
    if ($clientResponse -eq "approve") {
        $success = Update-GitHubIssue -headers $gitHubHeaders -repository $repository -approvalToken $approvalToken -status "approved"
        
        if ($success) {
            $response.Body = @"
<html>
<head><title>Request Approved</title>
<style>body{font-family:Arial,sans-serif;max-width:600px;margin:50px auto;padding:20px;text-align:center;}</style>
</head>
<body>
    <h1>✅ Request Approved!</h1>
    <p>Thank you for approving your website change request.</p>
    <p>Our AI development system is now working on your request.</p>
    <p><strong>Estimated completion: 15-30 minutes</strong></p>
</body>
</html>
"@
        }
    }
    elseif ($clientResponse -eq "reject") {
        $success = Update-GitHubIssue -headers $gitHubHeaders -repository $repository -approvalToken $approvalToken -status "rejected"
        
        if ($success) {
            $response.Body = @"
<html>
<head><title>Request Rejected</title>
<style>body{font-family:Arial,sans-serif;max-width:600px;margin:50px auto;padding:20px;text-align:center;}</style>
</head>
<body>
    <h1>❌ Request Marked for Clarification</h1>
    <p>Please reply to the original email with more specific details.</p>
</body>
</html>
"@
        }
    }
}
catch {
    Write-Error "Approval processing error: $($_.Exception.Message)"
    $response.StatusCode = [HttpStatusCode]::InternalServerError
    $response.Body = "<h1>Server Error</h1><p>Please contact support.</p>"
}

Push-OutputBinding -Name Response -Value $response
