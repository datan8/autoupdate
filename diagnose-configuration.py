#!/usr/bin/env python3
"""
Configuration Diagnostic Script
Helps identify the correct AWS and GitHub configuration for Amazon Q integration
"""

import json
import requests
import boto3
import subprocess
import sys

def load_config():
    """Load configuration from local.settings.json"""
    try:
        with open('local.settings.json', 'r') as f:
            config = json.load(f)
            return config['Values']
    except Exception as e:
        print(f"❌ Error loading config: {e}")
        return {}

def check_github_configuration():
    """Diagnose GitHub configuration issues"""
    print("🔍 DIAGNOSING GITHUB CONFIGURATION")
    print("=" * 50)
    
    config = load_config()
    github_token = config.get('GITHUB_TOKEN')
    
    if not github_token:
        print("❌ No GITHUB_TOKEN found in configuration")
        return
    
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json"
    }
    
    try:
        # Check authenticated user
        user_response = requests.get("https://api.github.com/user", headers=headers)
        user_response.raise_for_status()
        user = user_response.json()
        
        print(f"✅ GitHub User: {user['login']}")
        print(f"   Name: {user.get('name', 'Not set')}")
        print(f"   Type: {user['type']}")
        
        # Check organizations
        orgs_response = requests.get("https://api.github.com/user/orgs", headers=headers)
        orgs_response.raise_for_status()
        orgs = orgs_response.json()
        
        print(f"\n📋 Available Organizations:")
        if orgs:
            for org in orgs:
                print(f"   • {org['login']}")
        else:
            print("   No organizations found")
            
        # Check repositories
        repos_response = requests.get("https://api.github.com/user/repos?per_page=10", headers=headers)
        repos_response.raise_for_status()
        repos = repos_response.json()
        
        print(f"\n📁 Your Repositories (first 10):")
        for repo in repos[:10]:
            print(f"   • {repo['full_name']} ({'private' if repo['private'] else 'public'})")
            
        # Test current configuration
        current_org = config.get('GITHUB_ORG', '')
        current_repo = config.get('GITHUB_TEMPLATE_REPO', '')
        
        print(f"\n🎯 Current Configuration Test:")
        print(f"   GITHUB_ORG: {current_org}")
        print(f"   GITHUB_TEMPLATE_REPO: {current_repo}")
        
        if current_org and current_repo:
            test_url = f"https://api.github.com/repos/{current_org}/{current_repo}"
            test_response = requests.get(test_url, headers=headers)
            
            if test_response.status_code == 200:
                print("   ✅ Repository access: WORKING")
            elif test_response.status_code == 404:
                print("   ❌ Repository access: NOT FOUND")
                print(f"\n💡 Suggestions:")
                print(f"   1. Create repository: {current_org}/{current_repo}")
                print(f"   2. Or update GITHUB_ORG to: {user['login']}")
                print(f"   3. Or use one of your existing repositories")
            else:
                print(f"   ❌ Repository access: ERROR ({test_response.status_code})")
        
    except Exception as e:
        print(f"❌ GitHub diagnostic failed: {e}")

def check_aws_configuration():
    """Diagnose AWS configuration issues"""
    print("\n🔍 DIAGNOSING AWS CONFIGURATION")
    print("=" * 50)
    
    config = load_config()
    expected_account = config.get('AWS_ACCOUNT_ID', '')
    expected_region = config.get('AWS_REGION', 'us-east-1')
    app_id = config.get('AMAZON_Q_APPLICATION_ID', '')
    
    print(f"Expected AWS Account: {expected_account}")
    print(f"Expected Region: {expected_region}")
    print(f"Amazon Q App ID: {app_id}")
    
    try:
        # Check current AWS identity
        session = boto3.Session()
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        
        current_account = identity['Account']
        current_user = identity['Arn']
        
        print(f"\n✅ Current AWS Identity:")
        print(f"   Account: {current_account}")
        print(f"   User/Role: {current_user}")
        
        # Check account match
        if current_account == expected_account:
            print("   ✅ Account matches configuration")
        else:
            print(f"   ❌ Account mismatch!")
            print(f"   Expected: {expected_account}")
            print(f"   Current:  {current_account}")
            print(f"\n💡 Solutions:")
            print(f"   1. Update AWS_ACCOUNT_ID in local.settings.json to: {current_account}")
            print(f"   2. Or switch AWS profile to account {expected_account}")
        
        # Try to list Amazon Q applications
        try:
            qbusiness = session.client('qbusiness', region_name=expected_region)
            apps_response = qbusiness.list_applications()
            
            print(f"\n📱 Amazon Q Applications in {expected_region}:")
            if apps_response['applications']:
                for app in apps_response['applications']:
                    status_icon = "✅" if app['status'] == 'ACTIVE' else "⚠️"
                    print(f"   {status_icon} {app['displayName']} ({app['applicationId']})")
                    if app['applicationId'] == app_id:
                        print(f"      👆 This matches your configuration!")
            else:
                print("   No Amazon Q applications found")
                print(f"\n💡 Suggestions:")
                print(f"   1. Create an Amazon Q application in {expected_region}")
                print(f"   2. Or check other regions")
                print(f"   3. Or verify you have qbusiness permissions")
                
        except Exception as qb_error:
            print(f"❌ Cannot access Amazon Q Business: {qb_error}")
            print(f"\n💡 This might be because:")
            print(f"   1. Amazon Q Business is not available in {expected_region}")
            print(f"   2. Your user lacks qbusiness permissions")
            print(f"   3. The service is not enabled in your account")
            
    except Exception as e:
        print(f"❌ AWS diagnostic failed: {e}")
        print(f"\n💡 Make sure AWS credentials are configured:")
        print(f"   aws configure")

def suggest_configuration_updates():
    """Suggest configuration updates based on findings"""
    print("\n🔧 CONFIGURATION RECOMMENDATIONS")
    print("=" * 50)
    
    config = load_config()
    
    try:
        # Get current AWS account
        session = boto3.Session()
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        current_account = identity['Account']
        
        # Get GitHub user
        github_token = config.get('GITHUB_TOKEN')
        if github_token:
            headers = {"Authorization": f"Bearer {github_token}"}
            user_response = requests.get("https://api.github.com/user", headers=headers)
            if user_response.status_code == 200:
                github_user = user_response.json()['login']
                
                print("💡 Suggested local.settings.json updates:")
                print(json.dumps({
                    "AWS_ACCOUNT_ID": current_account,
                    "GITHUB_ORG": github_user,
                    "GITHUB_TEMPLATE_REPO": "sa-template"
                }, indent=2))
                
                print(f"\n🚀 Create the template repository:")
                print(f"curl -X POST \\")
                print(f"     -H 'Authorization: Bearer {github_token[:10]}...' \\")
                print(f"     -H 'Accept: application/vnd.github+json' \\")
                print(f"     https://api.github.com/user/repos \\")
                print(f"     -d '{{\"name\":\"sa-template\",\"description\":\"Amazon Q automation template\"}}'")
                
    except Exception as e:
        print(f"❌ Could not generate recommendations: {e}")

def main():
    """Main diagnostic function"""
    print("🔬 Amazon Q Integration Configuration Diagnostic")
    print("=" * 60)
    
    check_github_configuration()
    check_aws_configuration()
    suggest_configuration_updates()
    
    print(f"\n🎯 NEXT STEPS:")
    print(f"1. Fix any configuration issues identified above")
    print(f"2. Update local.settings.json with correct values")
    print(f"3. Create missing repositories if needed")
    print(f"4. Re-run: python3 amazon-q-integration-test.py")

if __name__ == "__main__":
    main()
