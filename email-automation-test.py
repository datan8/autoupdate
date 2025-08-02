#!/usr/bin/env python3
"""
Email-Driven Website Change Automation - Production Test
Python version implementing the PowerShell workflow
"""

import json
import requests
import time
from datetime import datetime
import urllib.parse

def load_config():
    """Load configuration from local.settings.json"""
    with open('local.settings.json', 'r') as f:
        config = json.load(f)
        return config['Values']

def classify_email_content(config, email_content):
    """Classify email content with OpenAI"""
    print("🤖 Classifying email content with OpenAI...")
    
    prompt = f"""Analyze this email content and determine if it's a bug report or feature request for a website change. 

Rules:
- If it describes something broken, not working, or an error: respond with "bug"
- If it requests new functionality or changes: respond with "feature"  
- If it's neither: respond with "neither"

For bug or feature, provide a clear, concise summary in this format:
[TYPE]: [SUMMARY]

Examples:
- bug: Contact page returns 404 error when refreshed
- feature: Add dark mode toggle to navigation menu
- neither

Email content: "{email_content}"
"""
    
    headers = {
        "Authorization": f"Bearer {config['OPENAI_API_KEY']}",
        "Content-Type": "application/json"
    }
    
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
        
        classification = response.json()['choices'][0]['message']['content'].strip()
        print(f"   ✅ OpenAI classification: {classification}")
        return classification
    except Exception as e:
        print(f"   ❌ OpenAI classification failed: {e}")
        return "neither"

def find_client_account(config, client_email):
    """Find client account in GoHighLevel"""
    print(f"👤 Finding client account for email: {client_email}")
    
    headers = {
        "Authorization": f"Bearer {config['GHL_API_KEY']}",
        "Content-Type": "application/json"
    }
    
    encoded_email = urllib.parse.quote(client_email)
    
    try:
        response = requests.get(
            f"https://rest.gohighlevel.com/v1/contacts/lookup?email={encoded_email}",
            headers=headers
        )
        response.raise_for_status()
        
        contact_result = response.json()
        if contact_result.get('contacts') and len(contact_result['contacts']) > 0:
            contact = contact_result['contacts'][0]
            account_id = contact['id']
            print(f"   ✅ Found account ID: {account_id}")
            
            # Try to find website URL in contact custom fields
            website_url = None
            if contact.get('customFields'):
                for field in contact['customFields']:
                    if 'website' in field.get('name', '').lower() or 'url' in field.get('name', '').lower():
                        website_url = field.get('value')
                        break
            
            if not website_url:
                website_url = contact.get('website')
            
            return {
                'AccountId': account_id,
                'WebsiteUrl': website_url,
                'Contact': contact
            }
        else:
            print("   ⚠️ No account found.")
            return None
    except Exception as e:
        print(f"   ❌ Failed to find account: {e}")
        return None

def get_client_repository(account_id, website_url):
    """Determine repository name based on account/website"""
    if website_url:
        try:
            from urllib.parse import urlparse
            uri = urlparse(website_url)
            domain = uri.netloc.replace('www.', '')
            repo_name = domain.replace('.', '-')
            print(f"   📁 Determined repository: {repo_name} from website: {website_url}")
            return repo_name
        except Exception as e:
            print(f"   ⚠️ Could not parse website URL: {website_url}")
    
    # Fallback to account-based naming
    repo_name = f"client-{account_id}"
    print(f"   📁 Using fallback repository: {repo_name}")
    return repo_name

def generate_approval_token():
    """Generate a unique approval token"""
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    import random
    random_num = random.randint(1000, 9999)
    return f"APPR-{timestamp}-{random_num}"

def create_github_issue(config, issue_type, title, description, repository, website_url, account_id, approval_token):
    """Create GitHub issue with Amazon Q labels"""
    print(f"📋 Creating GitHub Issue: {title}")
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    # Amazon Q specific labels for automated development
    labels = ["amazon-q", "client-request", "auto-generated"]
    if issue_type.lower() == "bug":
        labels.append("bug")
    elif issue_type.lower() == "feature":
        labels.append("enhancement")
    
    # Create detailed issue body with AI instructions
    ai_instructions = "Fix the described issue in the website code. Identify the root cause and implement a solution." if issue_type.lower() == "bug" else "Implement the requested feature. Follow best practices and ensure the implementation is user-friendly."
    
    current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
    
    issue_body = f"""## {issue_type.title()} Report

**Description:** {description}

**Website:** {website_url}
**Account ID:** {account_id}
**Approval Token:** {approval_token}
**Status:** Pending Client Approval

## AI Instructions
{ai_instructions}

## Next Steps
- [ ] Client approval received
- [ ] Code analysis completed  
- [ ] Solution implemented
- [ ] Testing completed
- [ ] Deployed to production

---
*This issue was created automatically from a client email request.*
*Generated on: {current_time}*
"""
    
    body = {
        "title": title,
        "body": issue_body,
        "labels": labels,
        "assignees": []  # Will be assigned after approval
    }
    
    try:
        url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repository}/issues"
        print(f"   🔗 Creating issue at: {url}")
        
        response = requests.post(url, headers=headers, json=body)
        response.raise_for_status()
        
        issue = response.json()
        print(f"   ✅ Created GitHub issue #{issue['number']}: {issue['html_url']}")
        
        return {
            'Number': issue['number'],
            'Url': issue['html_url'],
            'Id': issue['id']
        }
    except Exception as e:
        print(f"   ❌ Failed to create GitHub issue: {e}")
        if hasattr(e, 'response'):
            try:
                error_details = e.response.json()
                print(f"Error details: {error_details}")
            except:
                pass
        return None

def send_confirmation_email(config, client_email, content_summary, approve_link, reject_link, approval_token):
    """Send confirmation email to client using SendGrid"""
    print(f"📧 Sending confirmation email to client: {client_email}")
    
    current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
    
    html_content = f"""<!DOCTYPE html>
<html>
<head>
    <style>
        body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
        .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
        .header {{ background-color: #007bff; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }}
        .content {{ background-color: #f8f9fa; padding: 20px; border-radius: 5px; margin-bottom: 20px; }}
        .buttons {{ margin: 20px 0; text-align: center; }}
        .button {{ display: inline-block; padding: 15px 30px; color: white; text-decoration: none; border-radius: 5px; margin: 0 10px; font-weight: bold; }}
        .approve {{ background-color: #28a745; }}
        .reject {{ background-color: #dc3545; }}
        .footer {{ margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 12px; color: #666; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🔍 Confirm Your Website Change Request</h2>
        </div>
        <div class="content">
            <p>Dear Client,</p>
            <p>We've analyzed your email and interpreted it as the following:</p>
            <p><strong>Summary:</strong> {content_summary}</p>
            
            <p>To proceed with this change, please click one of the links below:</p>
            
            <div class="buttons">
                <a href="{approve_link}" class="button approve">[APPROVE ✅]</a>
                <a href="{reject_link}" class="button reject">[REJECT ❌]</a>
            </div>
            
            <p><strong>Approval Token:</strong> {approval_token}</p>
            
            <p>If you have any questions or need to provide additional details, please reply to this email.</p>
            
            <p>Best regards,<br>Your Website Automation Team</p>
        </div>
        <div class="footer">
            <p>This email was automatically generated by the email automation system.</p>
            <p>Generated on: {current_time}</p>
        </div>
    </div>
</body>
</html>"""

    text_content = f"""Confirm Your Website Change Request

Dear Client,

We've analyzed your email and interpreted it as the following:
Summary: {content_summary}

To proceed with this change, please click one of the links below:

[APPROVE ✅] {approve_link}

[REJECT ❌] {reject_link}

Approval Token: {approval_token}

If you have any questions or need to provide additional details, please reply to this email.

Best regards,
Your Website Automation Team

---
This email was automatically generated by the email automation system.
Generated on: {current_time}
"""

    headers = {
        "Authorization": f"Bearer {config['SENDGRID_API_KEY']}",
        "Content-Type": "application/json"
    }
    
    email_body = {
        "personalizations": [{"to": [{"email": client_email}]}],
        "from": {"email": config['EMAIL_FROM']},
        "subject": f"Confirm Your Website Change Request - Token: {approval_token}",
        "content": [
            {"type": "text/plain", "value": text_content},
            {"type": "text/html", "value": html_content}
        ],
        "tracking_settings": {
            "click_tracking": {"enable": False},
            "open_tracking": {"enable": False}
        }
    }
    
    try:
        response = requests.post(
            "https://api.sendgrid.com/v3/mail/send",
            headers=headers,
            json=email_body
        )
        response.raise_for_status()
        print("   ✅ Confirmation email sent successfully.")
        return True
    except Exception as e:
        print(f"   ❌ Failed to send confirmation email: {e}")
        return False

def simulate_approval_and_trigger_amazon_q(config, approval_token, repository):
    """Simulate client approval and trigger Amazon Q"""
    print(f"🎯 Simulating client approval for token: {approval_token}")
    
    headers = {
        "Authorization": f"Bearer {config['GITHUB_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "EmailAutomation/1.0"
    }
    
    try:
        # Search for issue with approval token
        search_url = f"https://api.github.com/search/issues?q=repo:{config['GITHUB_ORG']}/{repository}+{approval_token}+in:body+state:open"
        response = requests.get(search_url, headers=headers)
        response.raise_for_status()
        
        search_result = response.json()
        
        if search_result['total_count'] > 0:
            issue = search_result['items'][0]
            issue_number = issue['number']
            
            print(f"   📋 Found issue #{issue_number}")
            
            # Add Amazon Q ready labels
            update_body = {
                "labels": ["amazon-q", "approved", "amazon-q-ready", "help-wanted", "good-first-issue"]
            }
            
            update_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repository}/issues/{issue_number}"
            response = requests.patch(update_url, headers=headers, json=update_body)
            response.raise_for_status()
            
            # Add approval comment with @amazon-q mention
            comment_body = {
                "body": f"""✅ **Client Approval Received - SIMULATED FOR TESTING**

@amazon-q please help with this issue.

## Problem Summary
This issue has been approved by the client and is ready for AI implementation.

## Expected Solution
Please analyze the issue description and implement the appropriate solution.

## Technical Details
- This is an automated request from the email automation system
- Client approval token: {approval_token}
- Repository: {repository}

Please implement a solution and create a pull request.

Next steps:
- [x] Client approval received
- [ ] Code analysis completed  
- [ ] Solution implemented
- [ ] Testing completed
- [ ] Deployed to production

---
*Approval processed automatically at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC*"""
            }
            
            comment_url = f"https://api.github.com/repos/{config['GITHUB_ORG']}/{repository}/issues/{issue_number}/comments"
            response = requests.post(comment_url, headers=headers, json=comment_body)
            response.raise_for_status()
            
            print(f"   ✅ Issue #{issue_number} approved and Amazon Q triggered")
            print(f"   🔗 Issue URL: {issue['html_url']}")
            
            return {
                'success': True,
                'issue_number': issue_number,
                'issue_url': issue['html_url']
            }
        else:
            print(f"   ⚠️ No issue found with approval token: {approval_token}")
            return {'success': False, 'error': 'Issue not found'}
    except Exception as e:
        print(f"   ❌ Failed to process approval: {e}")
        return {'success': False, 'error': str(e)}

def main():
    """Main execution"""
    print("🚀 Email-Driven Website Change Automation - Production Test")
    print("=" * 60)
    
    # Load configuration
    config = load_config()
    
    # Test data
    test_data = {
        'client_email': 'john@datan8.com',
        'email_title': 'Bug in website',
        'email_body': 'Hi when I refresh the contact page it gives me a 404',
        'email_content': 'Bug in website: Hi when I refresh the contact page it gives me a 404'
    }
    
    print(f"📧 Processing test email case")
    print(f"   Email: {test_data['client_email']}")
    print(f"   Content: {test_data['email_content']}")
    
    # Step 1: Classify content using AI
    classification = classify_email_content(config, test_data['email_content'])
    if classification == "neither":
        print("   ⏭️ Skipping non-relevant case")
        return
    
    # Parse classification
    parts = classification.split(": ", 1)
    if len(parts) < 2:
        print(f"   ⚠️ Invalid classification format: {classification}")
        return
    
    issue_type = parts[0].strip()
    summary = parts[1].strip()
    
    print(f"   🎯 Classified as: {issue_type}")
    print(f"   📝 Summary: {summary}")
    
    # Step 2: Find client account (simulated for test)
    account_info = {
        'AccountId': 'test-account-001',
        'WebsiteUrl': 'https://example.com',
        'Contact': {'name': 'Test User'}
    }
    print(f"   👤 Using test account: {account_info['AccountId']}")
    
    # Step 3: Determine repository (use existing template for testing)
    repository = "sa-template"  # Use existing repository for testing
    print(f"   📁 Using test repository: {repository}")
    
    # Step 4: Generate approval token
    approval_token = generate_approval_token()
    print(f"   🎫 Generated approval token: {approval_token}")
    
    # Step 5: Create GitHub issue
    issue = create_github_issue(
        config, issue_type, summary, test_data['email_content'],
        repository, account_info['WebsiteUrl'], account_info['AccountId'], approval_token
    )
    
    if not issue:
        print("❌ Failed to create GitHub issue")
        return
    
    # Step 6: Generate approval links (simulated)
    approval_base_url = "https://yourfunction.azurewebsites.net"  # Would be real in production
    approve_link = f"{approval_base_url}/approve?token={approval_token}&repo={repository}"
    reject_link = f"{approval_base_url}/reject?token={approval_token}&repo={repository}"
    
    # Step 7: Send confirmation email
    email_sent = send_confirmation_email(
        config, test_data['client_email'], summary, 
        approve_link, reject_link, approval_token
    )
    
    if not email_sent:
        print("❌ Failed to send confirmation email")
        return
    
    print("\n⏳ Waiting 5 seconds before simulating approval...")
    time.sleep(5)
    
    # Step 8: Simulate approval and trigger Amazon Q
    approval_result = simulate_approval_and_trigger_amazon_q(config, approval_token, repository)
    
    # Final results
    print(f"\n🎉 Processing completed!")
    print(f"📊 Summary:")
    print(f"   - Email classified: ✅ {issue_type}")
    print(f"   - GitHub issue created: ✅ #{issue['Number']}")
    print(f"   - Confirmation email sent: ✅")
    print(f"   - Client approval simulated: {'✅' if approval_result['success'] else '❌'}")
    print(f"   - Amazon Q triggered: {'✅' if approval_result['success'] else '❌'}")
    
    if approval_result['success']:
        print(f"\n🔗 Links:")
        print(f"   📋 GitHub Issue: {approval_result['issue_url']}")
        print(f"   🎫 Approval Token: {approval_token}")
        print(f"   📂 Repository: {config['GITHUB_ORG']}/{repository}")
        
        print(f"\n🤖 Amazon Q Integration:")
        print(f"   - Issue has been labeled with 'amazon-q-ready'")
        print(f"   - Direct @amazon-q mention added to trigger AI")
        print(f"   - Amazon Q should analyze and create a PR within 5-15 minutes")
        
        print(f"\n🔄 Monitor Amazon Q progress:")
        print(f"   python3 check-amazon-q-status.py")
    else:
        print(f"\n❌ Approval simulation failed: {approval_result.get('error')}")

if __name__ == "__main__":
    main()
