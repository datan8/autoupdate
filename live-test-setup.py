#!/usr/bin/env python3
"""
Live Test Setup for Email-Driven Website Change Automation
Creates a test repository and demonstrates live GitHub API integration
"""

import json
import requests
import time
from datetime import datetime

def load_config():
    with open('local.settings.json', 'r') as f:
        config = json.load(f)
        return config['Values']

def test_github_connection(config):
    """Test GitHub API connection"""
    print("🔧 Testing GitHub API connection...")
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    try:
        # Test user access
        response = requests.get("https://api.github.com/user", headers=headers)
        if response.status_code == 200:
            user_data = response.json()
            print(f"   ✅ Connected as: {user_data['login']}")
            print(f"   🏢 Organization: {config['GITHUB_ORG']}")
            return headers
        else:
            print(f"   ❌ GitHub API Error: {response.status_code}")
            print(f"   Response: {response.text}")
            return None
    except Exception as e:
        print(f"   ❌ Connection error: {e}")
        return None

def create_test_repository(config, headers):
    """Create a test repository for the live demo"""
    repo_name = "client-live-test-001"
    print(f"🏗️ Creating test repository: {repo_name}")
    
    # Check if repo already exists
    check_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}"
    check_response = requests.get(check_url, headers=headers)
    
    if check_response.status_code == 200:
        print(f"   ℹ️ Repository already exists: https://github.com/{config['GITHUB_ORG']}/{repo_name}")
        return repo_name
    
    repo_data = {
        "name": repo_name,
        "description": "Test repository for email-driven automation with Amazon Q",
        "private": False,
        "auto_init": True,
        "has_issues": True,
        "has_projects": True,
        "has_wiki": False
    }
    
    # Try creating as organization repo first
    create_url = f"https://api.github.com/orgs/{config['GITHUB_ORG']}/repos"
    try:
        response = requests.post(create_url, headers=headers, json=repo_data)
        if response.status_code == 201:
            repo_info = response.json()
            print(f"   ✅ Created organization repository: {repo_info['html_url']}")
            return repo_name
        elif response.status_code == 404:
            # Not an organization, try as user repository
            print(f"   ℹ️ Not an organization, trying as user repository...")
            create_url = "https://api.github.com/user/repos"
            response = requests.post(create_url, headers=headers, json=repo_data)
            if response.status_code == 201:
                repo_info = response.json()
                print(f"   ✅ Created user repository: {repo_info['html_url']}")
                return repo_name
            else:
                print(f"   ❌ Failed to create user repository: {response.status_code}")
                print(f"   Response: {response.text}")
                return None
        else:
            print(f"   ❌ Failed to create repository: {response.status_code}")
            print(f"   Response: {response.text}")
            return None
    except Exception as e:
        print(f"   ❌ Error creating repository: {e}")
        return None

def setup_github_actions_workflow(config, headers, repo_name):
    """Add the GitHub Actions workflow to the repository"""
    print(f"⚙️ Setting up GitHub Actions workflow...")
    
    # Read the workflow file
    try:
        with open('.github/workflows/amazon-q-integration.yml', 'r') as f:
            workflow_content = f.read()
    except FileNotFoundError:
        print("   ❌ Workflow file not found!")
        return False
    
    # Create .github/workflows directory and file via GitHub API
    workflow_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/contents/.github/workflows/amazon-q-integration.yml"
    
    import base64
    encoded_content = base64.b64encode(workflow_content.encode('utf-8')).decode('utf-8')
    
    workflow_data = {
        "message": "Add Amazon Q integration workflow",
        "content": encoded_content,
        "branch": "main"
    }
    
    try:
        response = requests.put(workflow_url, headers=headers, json=workflow_data)
        if response.status_code in [201, 200]:
            print(f"   ✅ GitHub Actions workflow added")
            return True
        else:
            print(f"   ❌ Failed to add workflow: {response.status_code}")
            print(f"   Response: {response.text}")
            return False
    except Exception as e:
        print(f"   ❌ Error adding workflow: {e}")
        return False

def create_live_test_issue(config, headers, repo_name):
    """Create a real GitHub issue for testing"""
    print(f"📋 Creating live test issue...")
    
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    approval_token = f"APPR-{timestamp}-LIVE"
    
    issue_data = {
        "title": "LIVE TEST: Contact page returns 404 error when refreshed",
        "body": f"""## Bug Report - LIVE TEST

**Description:** Bug in website: Hi when I refresh the contact page it gives me a 404

**Website:** https://example-client-site.com
**Account ID:** live-test-001  
**Approval Token:** {approval_token}
**Status:** ⏳ LIVE TEST - Ready for Amazon Q

## AI Instructions for Amazon Q
Fix the described issue in the website code. This is a common single-page application routing issue where direct URL access to routes returns 404. 

**Technical Requirements:**
- Analyze the routing configuration 
- Implement proper server-side redirects (e.g., .htaccess for Apache or web.config for IIS)
- Ensure all routes are properly handled in the client-side router
- Add 404 error page handling
- Test that direct URL access works for all routes

**Expected Solution:**
- Update server configuration to serve index.html for all routes
- Verify client-side routing handles the contact page correctly
- Add proper error boundaries and 404 handling

## Next Steps  
- [x] Issue created automatically ✅
- [x] Labeled for Amazon Q processing ✅
- [ ] Amazon Q analyzes the issue
- [ ] Amazon Q implements code solution
- [ ] Pull request created with fixes
- [ ] Code review and testing
- [ ] Deploy to production

---
*This issue was created automatically from a live test of the email automation system.*
*Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC*
*System Status: 🟢 READY FOR AMAZON Q*""",
        "labels": ["amazon-q", "client-request", "auto-generated", "bug", "live-test"]
    }
    
    issue_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues"
    
    try:
        response = requests.post(issue_url, headers=headers, json=issue_data)
        if response.status_code == 201:
            issue_info = response.json()
            print(f"   ✅ Created issue #{issue_info['number']}: {issue_info['html_url']}")
            print(f"   🏷️ Labels: {', '.join([label['name'] for label in issue_info['labels']])}")
            return issue_info
        else:
            print(f"   ❌ Failed to create issue: {response.status_code}")
            print(f"   Response: {response.text}")
            return None
    except Exception as e:
        print(f"   ❌ Error creating issue: {e}")
        return None

def add_approved_label(config, headers, repo_name, issue_number):
    """Add approved label to trigger Amazon Q"""
    print(f"✅ Adding 'approved' label to trigger Amazon Q...")
    
    # Add approved label
    label_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}/labels"
    label_data = {"labels": ["approved", "amazon-q-ready"]}
    
    try:
        response = requests.post(label_url, headers=headers, json=label_data)
        if response.status_code == 200:
            print(f"   ✅ Added 'approved' and 'amazon-q-ready' labels")
            
            # Add comment to trigger Amazon Q
            comment_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}/comments"
            comment_data = {
                "body": """🤖 **LIVE TEST - Amazon Q Development Request**

This issue has been approved and is ready for automated development.

@amazon-q This is a live test of the email automation system. Please analyze the routing issue described above and implement a solution.

**Instructions for Amazon Q:**
- Read the issue description carefully
- This is a typical SPA (Single Page Application) routing problem
- Implement server-side redirect configuration  
- Fix client-side routing if needed
- Create a pull request with your implementation
- Link the PR back to this issue

**Technical Context:**
- Modern web application with client-side routing
- Contact page accessible via navigation but fails on direct URL access
- Needs proper server configuration for SPA routing
- Should include 404 error handling

Please proceed with implementation. This is a live test to verify the automation pipeline is working correctly.

---
*Automated comment generated by email automation system*
*Status: 🟢 READY FOR AI DEVELOPMENT*"""
            }
            
            comment_response = requests.post(comment_url, headers=headers, json=comment_data)
            if comment_response.status_code == 201:
                print(f"   ✅ Added trigger comment for Amazon Q")
                return True
            else:
                print(f"   ⚠️ Comment failed but labels added successfully")
                return True
        else:
            print(f"   ❌ Failed to add labels: {response.status_code}")
            return False
    except Exception as e:
        print(f"   ❌ Error adding labels: {e}")
        return False

def main():
    print("🚀 LIVE TEST SETUP - Email-Driven Website Change Automation")
    print("=" * 70)
    
    # Load configuration
    config = load_config()
    print(f"🏢 GitHub Organization: {config['GITHUB_ORG']}")
    
    # Test GitHub connection
    headers = test_github_connection(config)
    if not headers:
        print("❌ Cannot proceed without GitHub API access")
        return
    
    # Create test repository
    repo_name = create_test_repository(config, headers)
    if not repo_name:
        print("❌ Cannot proceed without test repository")
        return
    
    # Wait a moment for repository to be fully created
    print("⏳ Waiting for repository initialization...")
    time.sleep(3)
    
    # Setup GitHub Actions workflow
    workflow_success = setup_github_actions_workflow(config, headers, repo_name)
    if workflow_success:
        print("   ✅ Repository is ready for Amazon Q integration")
    
    # Create live test issue
    issue = create_live_test_issue(config, headers, repo_name)
    if not issue:
        print("❌ Cannot proceed without test issue")
        return
    
    # Add approved label to trigger Amazon Q
    if add_approved_label(config, headers, repo_name, issue['number']):
        print("   🚀 Issue is ready for Amazon Q processing!")
    
    print(f"\n🎯 LIVE TEST READY!")
    print(f"📋 Repository: https://github.com/{config['GITHUB_ORG']}/{repo_name}")
    print(f"🐛 Test Issue: {issue['html_url']}")
    print(f"⚙️ Actions: https://github.com/{config['GITHUB_ORG']}/{repo_name}/actions")
    
    print(f"\n📚 Next Steps:")
    print(f"1. Install Amazon Q GitHub App: https://github.com/marketplace/amazon-q-for-github")
    print(f"2. Configure Amazon Q for your organization: {config['GITHUB_ORG']}")
    print(f"3. Monitor the issue for Amazon Q activity")
    print(f"4. Check GitHub Actions for workflow execution")
    
    print(f"\n✨ The system is live and ready to test with Amazon Q!")

if __name__ == "__main__":
    main()
