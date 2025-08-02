#!/usr/bin/env python3
"""
Configure AWS credentials for Amazon Q Business account
"""
import os
import json
import subprocess

def main():
    print("🔧 AWS Credentials Configuration for Amazon Q")
    print("=" * 60)
    
    # Load current configuration
    try:
        with open('local.settings.json', 'r') as f:
            config = json.load(f)
        
        target_account = config['Values']['AWS_ACCOUNT_ID']
        region = config['Values']['AWS_REGION']
        
        print(f"📋 Target Configuration:")
        print(f"   • AWS Account: {target_account}")
        print(f"   • AWS Region: {region}")
        print(f"   • Amazon Q App: {config['Values']['AMAZON_Q_APPLICATION_ID']}")
        print()
        
    except Exception as e:
        print(f"❌ Error reading configuration: {e}")
        return
    
    print("🔑 Current AWS Credentials Status:")
    
    # Check current AWS configuration
    try:
        result = subprocess.run(['aws', 'sts', 'get-caller-identity'], 
                              capture_output=True, text=True, check=True)
        
        identity = json.loads(result.stdout)
        current_account = identity.get('Account')
        current_arn = identity.get('Arn')
        
        print(f"   ✅ Current Account: {current_account}")
        print(f"   ✅ Identity: {current_arn}")
        
        if current_account == target_account:
            print(f"   🎉 PERFECT! Your AWS credentials already match the Amazon Q account!")
            return test_amazon_q_access()
        else:
            print(f"   ⚠️  Account mismatch!")
            print(f"      • Current: {current_account}")
            print(f"      • Required: {target_account}")
            
    except subprocess.CalledProcessError as e:
        print(f"   ❌ AWS CLI error: {e}")
        print("   💡 Install AWS CLI: pip install awscli")
        return False
    except json.JSONDecodeError:
        print("   ❌ Invalid AWS CLI response")
        return False
    except FileNotFoundError:
        print("   ❌ AWS CLI not found")
        print("   💡 Install AWS CLI: pip install awscli")
        return False
    
    print()
    print("🚀 Next Steps to Fix AWS Credentials:")
    print("=" * 60)
    print("1. 🔑 Get AWS credentials for account 891376957673")
    print("   • Access AWS Console for account 891376957673")
    print("   • Go to IAM > Users > Your User > Security credentials")
    print("   • Create new Access Key if needed")
    print()
    print("2. 🛠️  Configure AWS CLI:")
    print("   aws configure")
    print("   • AWS Access Key ID: [your-access-key]")
    print("   • AWS Secret Access Key: [your-secret-key]")  
    print("   • Default region name: us-east-1")
    print("   • Default output format: json")
    print()
    print("3. ✅ Verify configuration:")
    print("   aws sts get-caller-identity")
    print("   # Should show Account: 891376957673")
    print()
    print("4. 🎯 Run test again:")
    print("   python3 configure-aws-for-amazon-q.py")
    print()
    
    return False

def test_amazon_q_access():
    """Test Amazon Q Business API access"""
    print()
    print("🧪 Testing Amazon Q Business Access...")
    
    try:
        import boto3
        from botocore.exceptions import ClientError
        
        # Load configuration
        with open('local.settings.json', 'r') as f:
            config = json.load(f)
        
        app_id = config['Values']['AMAZON_Q_APPLICATION_ID']
        region = config['Values']['AWS_REGION']
        
        # Create Amazon Q Business client
        client = boto3.client('qbusiness', region_name=region)
        
        # Test API access
        response = client.get_application(applicationId=app_id)
        
        print(f"   ✅ Amazon Q Application: {response['displayName']}")
        print(f"   ✅ Status: {response['status']}")
        print(f"   ✅ Created: {response['createdAt']}")
        print()
        print("🎉 SUCCESS! Amazon Q Business integration is working!")
        print("🚀 Your email automation system is fully operational!")
        
        return True
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'ResourceNotFoundException':
            print(f"   ❌ Amazon Q application not found in this account")
        elif error_code == 'AccessDeniedException':
            print(f"   ❌ Access denied - check IAM permissions")
        else:
            print(f"   ❌ AWS Error: {error_code}")
        return False
        
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False

if __name__ == "__main__":
    success = main()
    if not success:
        print("💡 After configuring AWS credentials, run this script again to verify!")
