#!/usr/bin/env python3
"""
Email-Driven Website Change Automation - Live Demo Simulation
Demonstrates the complete workflow from client email to GitHub issue creation
"""

import json
import time
from datetime import datetime
import requests

# Load configuration
def load_config():
    try:
        with open('local.settings.json', 'r') as f:
            config = json.load(f)
            return config['Values']
    except Exception as e:
        print(f"❌ Error loading config: {e}")
        return None

# Simulate OpenAI classification
def classify_email(content):
    print("🤖 Classifying email content with OpenAI...")
    time.sleep(1)
    
    if "404" in content.lower() or "not found" in content.lower() or "broken" in content.lower():
        return "bug", "Page not found error - needs routing fix"
    elif "add" in content.lower() or "new" in content.lower() or "feature" in content.lower():
        return "enhancement", "New feature request from client"
    else:
        return "bug", "General website issue reported by client"

# Simulate GitHub issue creation
def create_github_issue(config, issue_type, title, description, repo_name):
    print(f"📋 Creating GitHub Issue: {title}")
    print(f"   🔗 Would create issue at: https://api.github.com/repos/{config['GITHUB_ORG']}/{repo_name}/issues")
    
    # Generate approval token
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    token = f"APPR-{timestamp}-{hash(title) % 10000:04d}"
    
    issue_data = {
        "title": title,
        "body": f"""## {issue_type.title()} Report

**Description:** {description}

**Website:** https://example.com
**Account ID:** demo-client-001  
**Approval Token:** {token}
**Status:** Pending Client Approval

## AI Instructions
{'Fix the described issue in the website code. Identify the root cause and implement a solution.' if issue_type == 'bug' else 'Implement the requested feature following best practices and existing code patterns.'}

## Next Steps
- [ ] Client approval received
- [ ] Code analysis completed  
- [ ] Solution implemented
- [ ] Testing completed
- [ ] Deployed to production

---
*This issue was created automatically from a client email request.*
*Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC*""",
        "labels": ["amazon-q", "client-request", "auto-generated", issue_type]
    }
    
    return {
        "issue_number": 42,
        "issue_url": f"https://github.com/{config['GITHUB_ORG']}/{repo_name}/issues/42",
        "approval_token": token,
        "issue_data": issue_data
    }

# Simulate email sending
def send_approval_email(config, client_email, issue_summary, token, repo_name):
    print(f"📧 Sending confirmation email to client: {client_email}")
    
    email_content = f"""
Subject: Confirm Your Website Change Request - Token: {token}

Dear Client,

We've analyzed your email and interpreted it as the following:
Summary: {issue_summary}

To proceed with this change, please click one of the links below:

[APPROVE ✅] {config.get('APPROVAL_BASE_URL', 'https://yourfunction.azurewebsites.net')}/approve?token={token}&repo={repo_name}

[REJECT ❌] {config.get('APPROVAL_BASE_URL', 'https://yourfunction.azurewebsites.net')}/reject?token={token}&repo={repo_name}

Best regards,
Your Website Automation Team
    """
    
    print("   ✅ Confirmation email sent successfully.")
    print(f"   📧 Email preview:\n{email_content}")
    return True

def main():
    print("🤖 Email-Driven Website Change Automation - Live Demo")
    print("=" * 60)
    
    # Load configuration
    config = load_config()
    if not config:
        return
    
    print(f"⚙️ Initializing GitHub-based email automation script...")
    print(f"   🏢 GitHub Org: {config.get('GITHUB_ORG', 'Not configured')}")
    print(f"   📧 Email From: {config.get('EMAIL_FROM', 'Not configured')}")
    
    # Demo scenario
    print("\n📧 Demo Scenario:")
    client_email = "john@datan8.com"
    email_subject = "Bug in website"
    email_content = "Hi when I refresh the contact page it gives me a 404"
    
    print(f"   From: {client_email}")
    print(f"   Subject: {email_subject}")
    print(f"   Content: {email_content}")
    
    # Step 1: AI Classification
    print(f"\n📧 Processing case: demo-case-001")
    print(f"   Email: {client_email}")
    print(f"   Content: {email_content}")
    
    issue_type, classification = classify_email(email_content)
    print(f"   ✅ OpenAI classification: {issue_type}: {classification}")
    
    # Step 2: Client account lookup
    print(f"\n👤 Finding client account for email: {client_email}")
    client_id = "demo-client-001"
    website_url = "https://example.com"
    print(f"   ✅ Found account ID: {client_id}")
    print(f"   🌐 Website URL: {website_url}")
    
    # Step 3: Repository determination
    print(f"\n📦 Determining repository for client...")
    repo_name = f"client-{client_id}"
    print(f"   🏗️ Using repository: {repo_name}")
    
    # Step 4: GitHub issue creation
    result = create_github_issue(config, issue_type, classification, email_content, repo_name)
    print(f"   ✅ Created GitHub issue #{result['issue_number']}: {result['issue_url']}")
    
    print(f"\nLabels Applied:")
    for label in result['issue_data']['labels']:
        descriptions = {
            'amazon-q': '(triggers AI development)',
            'client-request': '(marks as client-originated)',
            'auto-generated': '(automated creation)',
            'bug': '(issue type)',
            'enhancement': '(issue type)'
        }
        print(f"• {label:<15} {descriptions.get(label, '')}")
    
    # Step 5: Send approval email
    print(f"\n📧 Client Approval Process:")
    send_approval_email(config, client_email, classification, result['approval_token'], repo_name)
    
    # Step 6: Summary
    print(f"\n🎉 Processing completed!")
    print(f"📊 Summary:")
    print(f"   - Cases processed: 1")
    print(f"   - GitHub issues created: 1")
    print(f"   - Approval emails sent: 1")
    
    print(f"\n📋 Created Issues:")
    print(f"   • #{result['issue_number']} ({issue_type}): {classification}")
    print(f"     Repository: {repo_name}")
    print(f"     Token: {result['approval_token']}")
    print(f"     Status: ⏳ PENDING APPROVAL")
    
    print(f"\n🚀 Next Steps:")
    print(f"   1. Client clicks approval link")
    print(f"   2. GitHub issue gets 'approved' label")
    print(f"   3. Amazon Q automatically triggered")
    print(f"   4. AI generates code fixes")
    print(f"   5. Pull request created for review")
    
    print(f"\n✨ The system is ready to handle real client emails!")
    print(f"📖 See DEMO_WALKTHROUGH.md for complete technical details")

if __name__ == "__main__":
    main()
