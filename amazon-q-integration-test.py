#!/usr/bin/env python3
"""
Amazon Q Business Integration Test
Tests the complete integration between email automation and Amazon Q Business
"""

import json
import requests
import boto3
from datetime import datetime
import os

def load_config():
    """Load configuration from local.settings.json"""
    with open('local.settings.json', 'r') as f:
        config = json.load(f)
        return config['Values']

def test_aws_credentials():
    """Test AWS credentials and Amazon Q access"""
    print("🔐 Testing AWS credentials and Amazon Q access...")
    
    config = load_config()
    
    try:
        # Initialize AWS session
        session = boto3.Session(region_name=config['AWS_REGION'])
        
        # Test STS to verify credentials
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        print(f"   ✅ AWS Account: {identity['Account']}")
        print(f"   ✅ User/Role: {identity['Arn']}")
        
        # Test Amazon Q Business client
        qbusiness = session.client('qbusiness', region_name=config['AWS_REGION'])
        
        # Get application details
        app_response = qbusiness.get_application(
            applicationId=config['AMAZON_Q_APPLICATION_ID']
        )
        
        print(f"   ✅ Amazon Q Application: {app_response['displayName']}")
        print(f"   ✅ Application Status: {app_response['status']}")
        print(f"   ✅ Application URL: {config['AMAZON_Q_DEPLOYED_URL']}")
        
        return True
        
    except Exception as e:
        print(f"   ❌ AWS/Amazon Q access failed: {e}")
        print("\n🔧 Setup Instructions:")
        print("   1. Install AWS CLI: pip install awscli")
        print("   2. Configure credentials: aws configure")
        print("   3. Ensure your AWS user has qbusiness permissions")
        return False

def test_github_integration():
    """Test GitHub API access and repository setup"""
    print("\n🐙 Testing GitHub integration...")
    
    config = load_config()
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github+json"
    }
    
    try:
        # Test GitHub API access
        user_response = requests.get("https://api.github.com/user", headers=headers)
        user_response.raise_for_status()
        user = user_response.json()
        print(f"   ✅ GitHub User: {user['login']}")
        
        # Test organization access
        org_response = requests.get(f"https://api.github.com/orgs/{config['GITHUB_ORG']}", headers=headers)
        org_response.raise_for_status()
        org = org_response.json()
        print(f"   ✅ GitHub Organization: {org['login']}")
        
        # Test repository access
        repo_response = requests.get(f"https://api.github.com/repos/{config['GITHUB_ORG']}/{config['GITHUB_TEMPLATE_REPO']}", headers=headers)
        repo_response.raise_for_status()
        repo = repo_response.json()
        print(f"   ✅ Template Repository: {repo['full_name']}")
        
        # Check if GitHub Actions are enabled
        actions_response = requests.get(f"https://api.github.com/repos/{config['GITHUB_ORG']}/{config['GITHUB_TEMPLATE_REPO']}/actions/workflows", headers=headers)
        if actions_response.status_code == 200:
            workflows = actions_response.json()
            print(f"   ✅ GitHub Actions: {workflows['total_count']} workflows found")
        else:
            print(f"   ⚠️ GitHub Actions: Unable to access workflows")
        
        return True
        
    except Exception as e:
        print(f"   ❌ GitHub integration failed: {e}")
        return False

def create_test_github_issue():
    """Create a test GitHub issue to verify Amazon Q integration"""
    print("\n📋 Creating test GitHub issue for Amazon Q...")
    
    config = load_config()
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github+json"
    }
    
    # Create test issue with Amazon Q labels
    issue_body = f"""## Test Issue for Amazon Q Integration

**Description:** This is a test issue to verify Amazon Q Business integration with the email automation system.

**Application ID:** {config['AMAZON_Q_APPLICATION_ID']}
**Application Name:** {config['AMAZON_Q_APPLICATION_NAME']}
**Test Created:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}

## AI Instructions
Please acknowledge this test issue and provide a sample response to verify the integration is working.

## Test Requirements
- Verify Amazon Q can read this issue
- Confirm the application can respond to @amazon-q mentions
- Test the workflow trigger mechanism

---
*This is a test issue created by the Amazon Q integration test script.*
"""
    
    labels = ["amazon-q", "test", "integration-test", "approved"]
    
    issue_data = {
        "title": "Amazon Q Integration Test - Please Respond",
        "body": issue_body,
        "labels": labels
    }
    
    try:
        response = requests.post(
            f"https://api.github.com/repos/{config['GITHUB_ORG']}/{config['GITHUB_TEMPLATE_REPO']}/issues",
            headers=headers,
            json=issue_data
        )
        response.raise_for_status()
        
        issue = response.json()
        print(f"   ✅ Test issue created: #{issue['number']}")
        print(f"   🔗 Issue URL: {issue['html_url']}")
        
        # Add a comment to trigger Amazon Q
        comment_data = {
            "body": f"""@amazon-q Hello! This is a test of the Amazon Q Business integration.

**Application Details:**
- Application ID: {config['AMAZON_Q_APPLICATION_ID']}
- Application Name: {config['AMAZON_Q_APPLICATION_NAME']}
- Deployed URL: {config['AMAZON_Q_DEPLOYED_URL']}

Please respond to this comment to verify the integration is working correctly.

**Expected Response:**
Please acknowledge this test and provide any guidance on how to improve the integration.
"""
        }
        
        comment_response = requests.post(
            f"https://api.github.com/repos/{config['GITHUB_ORG']}/{config['GITHUB_TEMPLATE_REPO']}/issues/{issue['number']}/comments",
            headers=headers,
            json=comment_data
        )
        comment_response.raise_for_status()
        
        print(f"   ✅ @amazon-q mention comment added")
        print(f"\n🔍 Monitor this issue for Amazon Q responses:")
        print(f"   {issue['html_url']}")
        
        return issue['number'], issue['html_url']
        
    except Exception as e:
        print(f"   ❌ Failed to create test issue: {e}")
        return None, None

def test_openai_integration():
    """Test OpenAI API for email classification"""
    print("\n🤖 Testing OpenAI integration...")
    
    config = load_config()
    headers = {
        "Authorization": f"Bearer {config['OPENAI_API_KEY']}",
        "Content-Type": "application/json"
    }
    
    test_email = "Bug report: The contact form on my website is not working properly and users can't submit messages."
    
    prompt = f"""Analyze this email content and determine if it's a bug report or feature request for a website change. 

Rules:
- If it describes something broken, not working, or an error: respond with "bug"
- If it requests new functionality or changes: respond with "feature"  
- If it's neither: respond with "neither"

For bug or feature, provide a clear, concise summary in this format:
[TYPE]: [SUMMARY]

Email content: "{test_email}"
"""
    
    body = {
        "model": config['OPENAI_MODEL'],
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 200,
        "temperature": 0.1
    }
    
    try:
        response = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers=headers,
            json=body
        )
        response.raise_for_status()
        
        result = response.json()
        classification = result['choices'][0]['message']['content'].strip()
        
        print(f"   ✅ OpenAI Model: {config['OPENAI_MODEL']}")
        print(f"   ✅ Test Email: {test_email[:50]}...")
        print(f"   ✅ Classification: {classification}")
        
        return True
        
    except Exception as e:
        print(f"   ❌ OpenAI integration failed: {e}")
        return False

def test_sendgrid_integration():
    """Test SendGrid email delivery"""
    print("\n📧 Testing SendGrid integration...")
    
    config = load_config()
    headers = {
        "Authorization": f"Bearer {config['SENDGRID_API_KEY']}",
        "Content-Type": "application/json"
    }
    
    # Test email content
    email_body = {
        "personalizations": [{"to": [{"email": config['EMAIL_TO']}]}],
        "from": {"email": config['EMAIL_FROM']},
        "subject": "Amazon Q Integration Test - Email System Working",
        "content": [
            {
                "type": "text/plain", 
                "value": f"""Amazon Q Integration Test Email

This email confirms that the SendGrid integration is working correctly.

Test Details:
- Amazon Q Application: {config['AMAZON_Q_APPLICATION_NAME']}
- Application ID: {config['AMAZON_Q_APPLICATION_ID']}
- Test Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}

The email automation system is ready for production use.

Best regards,
Email Automation System
"""
            }
        ]
    }
    
    try:
        response = requests.post(
            "https://api.sendgrid.com/v3/mail/send",
            headers=headers,
            json=email_body
        )
        response.raise_for_status()
        
        print(f"   ✅ SendGrid API: Working")
        print(f"   ✅ Test email sent to: {config['EMAIL_TO']}")
        print(f"   ✅ From address: {config['EMAIL_FROM']}")
        
        return True
        
    except Exception as e:
        print(f"   ❌ SendGrid integration failed: {e}")
        return False

def generate_integration_report(tests_passed, issue_number=None, issue_url=None):
    """Generate comprehensive integration report"""
    print("\n" + "="*70)
    print("🎯 AMAZON Q BUSINESS INTEGRATION REPORT")
    print("="*70)
    
    config = load_config()
    
    print(f"\n📊 Configuration Summary:")
    print(f"   • Amazon Q Application: {config['AMAZON_Q_APPLICATION_NAME']}")
    print(f"   • Application ID: {config['AMAZON_Q_APPLICATION_ID']}")
    print(f"   • AWS Account: {config['AWS_ACCOUNT_ID']}")
    print(f"   • AWS Region: {config['AWS_REGION']}")
    print(f"   • GitHub Organization: {config['GITHUB_ORG']}")
    print(f"   • Template Repository: {config['GITHUB_TEMPLATE_REPO']}")
    
    print(f"\n✅ Test Results:")
    for test_name, passed in tests_passed.items():
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"   • {test_name}: {status}")
    
    passed_count = sum(tests_passed.values())
    total_count = len(tests_passed)
    
    print(f"\n📈 Overall Status: {passed_count}/{total_count} tests passed")
    
    if issue_number and issue_url:
        print(f"\n🔗 Test Issue Created:")
        print(f"   • Issue #{issue_number}: {issue_url}")
        print(f"   • Monitor this issue for Amazon Q responses")
    
    print(f"\n🚀 Next Steps:")
    if passed_count == total_count:
        print("   ✅ All tests passed! The system is ready for production.")
        print("   • Deploy PowerShell script to Azure Functions")
        print("   • Set up email polling/webhook triggers")
        print("   • Configure client repository templates")
        print("   • Test end-to-end workflow with real emails")
    else:
        print("   ⚠️ Some tests failed. Review the errors above and:")
        failed_tests = [name for name, passed in tests_passed.items() if not passed]
        for test in failed_tests:
            if test == "AWS & Amazon Q":
                print("     • Configure AWS credentials with qbusiness permissions")
            elif test == "GitHub Integration":
                print("     • Verify GitHub token permissions and repository access")
            elif test == "OpenAI Integration":
                print("     • Check OpenAI API key and model access")
            elif test == "SendGrid Integration":
                print("     • Verify SendGrid API key and sender authentication")
    
    print(f"\n💡 Amazon Q Integration Notes:")
    print(f"   • The test issue includes @amazon-q mention")
    print(f"   • Check if Amazon Q responds within 5-15 minutes")
    print(f"   • If no response, verify Amazon Q GitHub integration")
    print(f"   • Consider setting up data source connections in Amazon Q Business")

def main():
    """Main test execution"""
    print("🚀 Amazon Q Business Integration Test Suite")
    print("="*50)
    
    tests_passed = {}
    
    # Run all integration tests
    tests_passed["AWS & Amazon Q"] = test_aws_credentials()
    tests_passed["GitHub Integration"] = test_github_integration()
    tests_passed["OpenAI Integration"] = test_openai_integration()
    tests_passed["SendGrid Integration"] = test_sendgrid_integration()
    
    # Create test issue for Amazon Q
    issue_number, issue_url = create_test_github_issue()
    
    # Generate comprehensive report
    generate_integration_report(tests_passed, issue_number, issue_url)

if __name__ == "__main__":
    main()
