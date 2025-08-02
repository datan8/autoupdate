# Amazon Q Integration Troubleshooting Guide

## Test Results Summary ✅❌

| Integration | Status | Details |
|-------------|--------|---------|
| OpenAI | ✅ PASS | Working perfectly with gpt-4o-mini |
| SendGrid | ✅ PASS | Email delivery working |
| AWS/Amazon Q | ❌ FAIL | Account mismatch issue |
| GitHub | ❌ FAIL | Organization access issue |

## Issues Found and Solutions

### 🔴 Issue 1: AWS Account Mismatch

**Problem:** 
- Your local AWS credentials point to account `352383909247`
- But Amazon Q application is in account `891376957673`
- Application ID `cec916d8-66d8-43ea-a254-f0ab0844396f` not found in your current account

**Solutions:**

#### Option A: Switch AWS Profile (Recommended)
```bash
# Check available AWS profiles
aws configure list-profiles

# If you have a profile for the correct account:
export AWS_PROFILE=your-amazon-q-profile

# Or set temporarily:
aws configure set aws_access_key_id YOUR_KEY --profile amazon-q
aws configure set aws_secret_access_key YOUR_SECRET --profile amazon-q
aws configure set region us-east-1 --profile amazon-q
export AWS_PROFILE=amazon-q
```

#### Option B: Get Credentials for Account 891376957673
You need AWS credentials that have access to the account where your Amazon Q application is deployed (`891376957673`).

#### Option C: Cross-Account Access (Advanced)
Set up cross-account role assumption if the Amazon Q application is in a different account.

### 🔴 Issue 2: GitHub Organization Access

**Problem:**
- Organization `bosoleil` returns 404
- Repository `sa-template` not accessible

**Solutions:**

#### Check GitHub Organization
```bash
# Test with curl
curl -H "Authorization: Bearer YOUR_GITHUB_TOKEN" \
     https://api.github.com/user/orgs

# Check if it's a user account instead of organization
curl -H "Authorization: Bearer YOUR_GITHUB_TOKEN" \
     https://api.github.com/users/bosoleil
```

#### Possible Fixes:
1. **User vs Organization**: If `bosoleil` is a user account, not an organization:
   - Update `GITHUB_ORG` to your actual username
   - Or create the repository under your user account

2. **Create Repository**: Create the `sa-template` repository:
   ```bash
   # Create repository via API
   curl -X POST -H "Authorization: Bearer YOUR_GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user/repos \
        -d '{"name":"sa-template","description":"Website automation template"}'
   ```

3. **Update Configuration**: If you're using a different organization/user:

## Quick Fix Commands

### 1. Fix GitHub Configuration
```bash
# Test your GitHub access
curl -H "Authorization: Bearer $(grep GITHUB_TOKEN local.settings.json | cut -d'"' -f4)" \
     https://api.github.com/user

# Create the template repository
curl -X POST \
     -H "Authorization: Bearer $(grep GITHUB_TOKEN local.settings.json | cut -d'"' -f4)" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/user/repos \
     -d '{"name":"sa-template","description":"Amazon Q automation template","private":false}'
```

### 2. Fix AWS Configuration
```bash
# Check current AWS identity
aws sts get-caller-identity

# If wrong account, configure the correct one
aws configure --profile amazon-q
# Enter credentials for account 891376957673

# Use the profile
export AWS_PROFILE=amazon-q
aws sts get-caller-identity  # Should show account 891376957673
```

## Updated Configuration Needed

Based on your actual setup, you may need to update `local.settings.json`:

```json
{
  "Values": {
    "GITHUB_ORG": "your-actual-github-username-or-org",
    "AWS_ACCOUNT_ID": "352383909247",  // Use your actual AWS account
    "AMAZON_Q_APPLICATION_ID": "your-actual-application-id"  // Get from your AWS account
  }
}
```

## Next Steps

1. **Fix GitHub Access**:
   - Verify your GitHub organization/username
   - Create the `sa-template` repository
   - Test repository access

2. **Fix AWS Access**:
   - Either get credentials for account 891376957673
   - Or find your Amazon Q application in account 352383909247
   - Update configuration accordingly

3. **Re-run Test**:
   ```bash
   python3 amazon-q-integration-test.py
   ```

4. **Test PowerShell Script**:
   ```bash
   pwsh change-automation-pt1.ps1
   ```

## Verification Commands

```bash
# Test GitHub access
gh api user  # Using GitHub CLI
# or
curl -H "Authorization: Bearer YOUR_TOKEN" https://api.github.com/user

# Test AWS access
aws sts get-caller-identity

# List Amazon Q applications
aws qbusiness list-applications --region us-east-1

# Test the full integration
python3 amazon-q-integration-test.py
```

## Contact Information

If you need help with:
- AWS account access → Contact your AWS administrator
- GitHub repository setup → Check GitHub organization settings
- Amazon Q configuration → Review AWS Q Business console

Run the test again after making these fixes!
