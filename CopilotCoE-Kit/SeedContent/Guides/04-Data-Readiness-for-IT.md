# Data readiness checklist for IT

> Steps to complete before assigning paid Copilot licenses: fix oversharing, set guardrails, and monitor.

Premium Copilot can find anything a user is already able to open. It does not create new access, but it makes existing oversharing easy to discover. Complete these steps before the first paid licenses, then repeat on a schedule.

## 1. Find and fix oversharing

1. Run the SharePoint Advanced Management data access governance reports and content management assessment. Microsoft suggests repeating the assessment about every 30 days.
2. Review sites shared with "Everyone except external users," organization-wide sharing links, and sites without active owners.
3. Prioritize sites that hold student records, advising notes, financial aid, HR, health, and research data.
4. Use **Restricted Content Discovery** to keep sensitive sites out of Copilot and search results while owners clean up permissions.
5. Assign an accountable owner to each high-risk site.

## 2. Set guardrails

- Publish and apply sensitivity labels for confidential and highly confidential organizational information.
- Create data loss prevention rules for Copilot that cover the organization's restricted categories, including credentials, keys, and security configuration.
- Tell IT staff not to paste security designs, firewall rules, or vulnerability findings into Copilot unless the organization's data rules allow it.
- Turn on audit for Copilot interactions and confirm who can search the logs.
- Decide retention for Copilot conversations with the records officer, including public-records and FERPA obligations.
- Set agent sharing and creation policies before announcing agents (see the agents guide).

## 3. Prepare the service

- Confirm users can reach copilot.cloud.microsoft and related service endpoints through campus networks and proxies.
- Pin Copilot for users, plan the welcome message, and enable in-product feedback.
- For students, set the education tenant classification to Higher Education and confirm age-group settings for any learners under 18, such as dual-enrollment students.
- Brief the service desk on license tiers, sign-in with work or school versus personal accounts, and how to escalate data concerns.

## 4. Monitor

- Review Copilot usage reports monthly. The Copilot Chat report covers users without a paid license.
- Re-run oversharing reports after reorganizations, site migrations, and each license wave.
- Review data security posture and audit results with the security and privacy leads.

Record the owner, completion date, and evidence for each step before the release gate.

## Microsoft guidance

- [Secure and governed data foundation for Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/configure-secure-governed-data-foundation-microsoft-365-copilot)
- [Get ready for Copilot with SharePoint Advanced Management](https://learn.microsoft.com/en-us/microsoft-365/copilot/get-ready-copilot-sharepoint-advanced-management)
- [Restricted Content Discovery](https://learn.microsoft.com/en-us/sharepoint/restricted-content-discovery)
- [Microsoft Purview protections for Copilot](https://learn.microsoft.com/en-us/purview/ai-m365-copilot)
- [Data Security Posture Management](https://learn.microsoft.com/en-us/purview/data-security-posture-management-learn-about)
- [Audit logs for Copilot](https://learn.microsoft.com/en-us/purview/audit-copilot)
- [Retention for Copilot](https://learn.microsoft.com/en-us/purview/retention-policies-copilot)
- [Enable Copilot Chat for learners](https://learn.microsoft.com/en-us/microsoft-365/education/guide/1-reference/enable-copilot-chat-for-learners)
- [Copilot usage reports for admins](https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-reports-for-admins)
