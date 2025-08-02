#!/usr/bin/env python3
"""
Direct Amazon Q Trigger - Add a more direct comment to trigger Amazon Q
Sometimes Amazon Q responds better to direct mentions and specific formatting
"""

import json
import requests
from datetime import datetime

def load_config():
    with open('local.settings.json', 'r') as f:
        config = json.load(f)
        return config['Values']

def trigger_amazon_q_direct(config):
    """Add a direct trigger comment for Amazon Q"""
    repo_name = "client-live-test-001"
    issue_number = 1
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    print(f"🤖 Adding direct Amazon Q trigger comment...")
    
    # Add a more direct comment to trigger Amazon Q
    comment_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}/comments"
    
    # Create a very direct Amazon Q trigger comment
    comment_data = {
        "body": f"""@amazon-q please help with this issue.

## Problem Summary
Contact page returns 404 error when refreshed in a single-page application.

## Expected Solution
Fix the routing configuration so that direct URL access to `/contact` works properly.

## Technical Details
- This is a typical SPA routing issue
- Need server-side configuration (like .htaccess) to serve index.html for all routes
- Client-side router should handle the `/contact` route properly

Please implement a solution and create a pull request.

---
*Direct trigger comment added at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC*"""
    }
    
    try:
        response = requests.post(comment_url, headers=headers, json=comment_data)
        if response.status_code == 201:
            print(f"   ✅ Direct trigger comment added successfully")
            print(f"   🔗 Comment URL: https://github.com/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}")
            return True
        else:
            print(f"   ❌ Failed to add comment: {response.status_code}")
            print(f"   Response: {response.text}")
            return False
    except Exception as e:
        print(f"   ❌ Error adding comment: {e}")
        return False

def add_help_wanted_label(config):
    """Add help-wanted label which Amazon Q might respond to"""
    repo_name = "client-live-test-001"
    issue_number = 1
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    print(f"🏷️ Adding help-wanted label...")
    
    label_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}/labels"
    label_data = {"labels": ["help-wanted", "good-first-issue"]}
    
    try:
        response = requests.post(label_url, headers=headers, json=label_data)
        if response.status_code == 200:
            print(f"   ✅ Added help-wanted label")
            return True
        else:
            print(f"   ⚠️ Label may already exist or other issue: {response.status_code}")
            return True  # Not critical
    except Exception as e:
        print(f"   ❌ Error adding label: {e}")
        return False

def check_amazon_q_configuration(config):
    """Provide guidance on Amazon Q configuration"""
    print(f"\n🔧 Amazon Q Configuration Check:")
    print(f"   📋 Repository: https://github.com/{config['GITHUB_ORG']}/client-live-test-001")
    print(f"   🤖 Amazon Q should be installed for account: {config['GITHUB_ORG']}")
    
    print(f"\n📚 If Amazon Q isn't responding, verify:")
    print(f"   1. Amazon Q is installed: https://github.com/settings/installations")
    print(f"   2. Amazon Q has access to the repository")
    print(f"   3. Repository has 'Issues' enabled")
    print(f"   4. Amazon Q permissions include 'Read and write' access")
    
    print(f"\n🔄 Alternative triggers to try:")
    print(f"   • Visit the issue and manually mention @amazon-q")
    print(f"   • Add the 'help wanted' label")
    print(f"   • Create a simple README.md with code that needs fixing")

def main():
    print("🚀 Direct Amazon Q Trigger - Live Test")
    print("=" * 50)
    
    config = load_config()
    
    # Add direct trigger comment
    trigger_success = trigger_amazon_q_direct(config)
    
    # Add help-wanted label
    label_success = add_help_wanted_label(config)
    
    # Provide configuration guidance
    check_amazon_q_configuration(config)
    
    if trigger_success:
        print(f"\n✅ Direct trigger added successfully!")
        print(f"⏰ Amazon Q typically responds within 5-15 minutes")
        print(f"🔄 Run 'python3 check-amazon-q-status.py' to monitor progress")
    else:
        print(f"\n❌ Failed to add direct trigger")
    
    print(f"\n🌐 Monitor here: https://github.com/{config['GITHUB_ORG']}/client-live-test-001/issues/1")

if __name__ == "__main__":
    main()
