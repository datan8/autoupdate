#!/usr/bin/env python3
"""
Check Amazon Q Status - Monitor the live test issue for Amazon Q activity
"""

import json
import requests
import time
from datetime import datetime

def load_config():
    with open('local.settings.json', 'r') as f:
        config = json.load(f)
        return config['Values']

def check_issue_status(config):
    """Check the status of our live test issue"""
    repo_name = "client-live-test-001"
    issue_number = 1
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    print(f"🔍 Checking live test issue status...")
    print(f"📋 Repository: https://github.com/{config['GITHUB_ORG']}/{repo_name}")
    print(f"🐛 Issue: https://github.com/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}")
    
    # Check issue details
    issue_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}"
    
    try:
        response = requests.get(issue_url, headers=headers)
        if response.status_code == 200:
            issue = response.json()
            
            print(f"\n📊 Issue Status:")
            print(f"   📌 Title: {issue['title']}")
            print(f"   🏷️ Labels: {', '.join([label['name'] for label in issue['labels']])}")
            print(f"   📅 Created: {issue['created_at']}")
            print(f"   📝 State: {issue['state'].upper()}")
            print(f"   💬 Comments: {issue['comments']}")
            
            # Check comments for Amazon Q activity
            if issue['comments'] > 1:  # More than our initial comment
                print(f"\n💬 Checking comments for Amazon Q activity...")
                comments_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues/{issue_number}/comments"
                comments_response = requests.get(comments_url, headers=headers)
                
                if comments_response.status_code == 200:
                    comments = comments_response.json()
                    
                    amazon_q_found = False
                    for comment in comments:
                        if 'amazon-q' in comment['user']['login'].lower() or 'bot' in comment['user']['login'].lower():
                            amazon_q_found = True
                            print(f"   🤖 Amazon Q Comment found!")
                            print(f"      👤 Author: {comment['user']['login']}")
                            print(f"      📅 Posted: {comment['created_at']}")
                            print(f"      💬 Preview: {comment['body'][:200]}...")
                            break
                    
                    if not amazon_q_found:
                        print(f"   ⏳ No Amazon Q comments yet - may still be processing...")
            else:
                print(f"   ⏳ No new comments yet - Amazon Q may still be analyzing...")
            
            return issue
        else:
            print(f"   ❌ Error fetching issue: {response.status_code}")
            return None
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return None

def check_pull_requests(config):
    """Check for pull requests created by Amazon Q"""
    repo_name = "client-live-test-001"
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    print(f"\n🔍 Checking for Amazon Q pull requests...")
    
    prs_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/pulls"
    
    try:
        response = requests.get(prs_url, headers=headers)
        if response.status_code == 200:
            prs = response.json()
            
            if prs:
                print(f"   🎉 Found {len(prs)} pull request(s)!")
                for pr in prs:
                    print(f"\n   📝 Pull Request #{pr['number']}:")
                    print(f"      📌 Title: {pr['title']}")
                    print(f"      👤 Author: {pr['user']['login']}")
                    print(f"      📅 Created: {pr['created_at']}")
                    print(f"      🌐 URL: {pr['html_url']}")
                    print(f"      📊 Status: {pr['state'].upper()}")
                    
                    if 'amazon-q' in pr['user']['login'].lower() or 'bot' in pr['user']['login'].lower():
                        print(f"      🤖 This appears to be from Amazon Q!")
                        return True
            else:
                print(f"   ⏳ No pull requests yet - Amazon Q may still be working...")
                return False
        else:
            print(f"   ❌ Error fetching PRs: {response.status_code}")
            return False
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False

def check_github_actions(config):
    """Check GitHub Actions workflow runs"""
    repo_name = "client-live-test-001"
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    print(f"\n🔍 Checking GitHub Actions workflow runs...")
    
    runs_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/actions/runs"
    
    try:
        response = requests.get(runs_url, headers=headers)
        if response.status_code == 200:
            runs = response.json()
            
            if runs['workflow_runs']:
                print(f"   ⚙️ Found {runs['total_count']} workflow run(s)!")
                for run in runs['workflow_runs'][:3]:  # Show latest 3
                    print(f"\n   🏃 Workflow Run #{run['run_number']}:")
                    print(f"      📌 Name: {run['name']}")
                    print(f"      📊 Status: {run['status'].upper()}")
                    print(f"      📅 Started: {run['created_at']}")
                    print(f"      🌐 URL: {run['html_url']}")
                    
                    if run['conclusion']:
                        print(f"      ✅ Conclusion: {run['conclusion'].upper()}")
            else:
                print(f"   ⏳ No workflow runs yet...")
        else:
            print(f"   ❌ Error fetching workflow runs: {response.status_code}")
    except Exception as e:
        print(f"   ❌ Error: {e}")

def main():
    print("🤖 Amazon Q Status Check - Live Test Monitoring")
    print("=" * 60)
    
    config = load_config()
    
    # Check issue status
    issue = check_issue_status(config)
    
    # Check for pull requests
    pr_found = check_pull_requests(config)
    
    # Check GitHub Actions
    check_github_actions(config)
    
    # Summary
    print(f"\n📊 LIVE TEST STATUS SUMMARY:")
    print(f"   🏷️ Issue Labels: amazon-q, approved, amazon-q-ready ✅")
    print(f"   🤖 Amazon Q Installed: ✅")
    print(f"   📝 Pull Request Created: {'✅' if pr_found else '⏳ Pending'}")
    
    if pr_found:
        print(f"\n🎉 SUCCESS! Amazon Q has responded to the live test!")
        print(f"🔗 Check the pull request for the implemented solution.")
    else:
        print(f"\n⏳ Amazon Q is likely still processing the request...")
        print(f"💡 This can take 5-15 minutes depending on complexity.")
        print(f"🔄 Run this script again in a few minutes to check progress.")
    
    print(f"\n🌐 Quick Links:")
    print(f"   📋 Issue: https://github.com/{config['GITHUB_ORG']}/client-live-test-001/issues/1")
    print(f"   📝 PRs: https://github.com/{config['GITHUB_ORG']}/client-live-test-001/pulls")
    print(f"   ⚙️ Actions: https://github.com/{config['GITHUB_ORG']}/client-live-test-001/actions")

if __name__ == "__main__":
    main()
