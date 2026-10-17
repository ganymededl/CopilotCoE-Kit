# Data protection
> Protect information before using Copilot or publishing an agent. These examples are not an adopted organizational policy.

## Start with the data and its owner

| Example data level | Examples | Starter AI guidance |
|---|---|---|
| Public | Published reports and public notices | Use only organization-approved tools; check accuracy and ownership |
| Internal | Drafts and planning documents | Use an approved work-account experience only when the data owner allows it |
| Confidential or regulated | Student or personnel records, health, financial or case files | No use without explicit organizational authorization for that data and purpose |

Follow {{Link:AIGuidelines|your organization's AI and classification rules}}. If that route is not configured, ask the data owner; this page grants no exception.

## Controls to check

1. **Permissions and oversharing.** Copilot respects existing access; it can make overbroad access easier to find. Review site membership, sharing links, source ownership and search/discovery controls.
2. **Sensitivity labels.** Publish the labels and encryption rules approved by the organization; test how content with those labels behaves in the intended Copilot experience.
3. **Data loss prevention.** Security owners choose and test Purview DLP policies for Copilot and agents; a sample rule is not a deployed control. Check supported locations and cloud capabilities.
4. **Monitoring and records.** Assign an authorized audit owner and retention schedule. Do not store sensitive prompts or agent test evidence in a public list.
5. **Agents and builders.** Review the knowledge sources, connectors, actions, environment, billing and reader permissions before sharing. A Showcase listing does not grant access or platform approval.

IT's operational steps remain in the separate [Data readiness for IT](Guide-Data-Readiness-for-IT.aspx) checklist. See [Agent lifecycle and approval](Agent-Lifecycle-and-Approval.aspx).

**Data or safety concern?** {{Link:DataSafetyIncident|Report a data or safety incident}} using the configured route, not general feedback. If the route is not configured, ask for the approved route without sending sensitive details.

Microsoft guidance: [Purview protection for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/purview/ai-m365-copilot) and [secure, governed data foundation](https://learn.microsoft.com/en-us/microsoft-365/copilot/configure-secure-governed-data-foundation-microsoft-365-copilot).
