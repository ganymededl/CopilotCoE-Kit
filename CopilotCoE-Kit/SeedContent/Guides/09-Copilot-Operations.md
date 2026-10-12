# Copilot operations for IT
> How IT and the CoE review and release agents, check them before release, respond to incidents, and keep the service healthy.

This guide adapts common operating practice to your organization. Replace role names, queues, and thresholds with local ones before production use.

## Agent intake and release

1. **Intake.** Capture the purpose, intended users, data sources, named owner, expected outcome, and risk tier (see Governance and Responsible AI).
2. **Assess.** Check permissions, sensitivity labels, grounding sources, human-review points, and accessibility.
3. **Test.** Run representative prompts, prompt-injection tests, citation and freshness checks, and failure-mode tests.
4. **Approve.** Record the CoE, data-owner, and security decisions. Missing evidence means the request is returned, not approved.
5. **Release.** Publish to the smallest pilot group, explain limitations to users, and monitor usage and incidents.
6. **Review.** Review monthly during the pilot and quarterly after that. Retire the agent when the owner leaves or the value case ends.

## Release is blocked when

- permissions are broader than intended;
- sources are stale, uncited, or not approved for the data level;
- there is no human review for a consequential use;
- accessibility checks fail; or
- critical test defects remain open.

## Incidents and service restoration

{{Link:DataSafetyIncident|Report a data or safety incident}}. Stop using affected content; do not post sensitive details in Teams, general feedback or email.{{IfRouteMissing:DataSafetyIncident| If the route is not configured, use an existing approved organizational incident route if known, or ask for the correct route without sensitive details. This page does not submit a report.}} Only authorized responders should change production settings or preserve sensitive evidence in approved storage.

| Situation | Immediate action | Route |
|---|---|---|
| Suspected data exposure | Stop use; authorized responders contain exposure and preserve evidence in approved storage | Separate incident route above |
| Incorrect consequential output | Stop use, correct it with a qualified person, and notify the authorized owner through approved channels | Separate incident route above and authorized data owner |
| Service unavailable | Check Microsoft 365 Service health and the pilot scope | {{Link:ServiceDesk|IT service desk}}, then IT platform owner |
| Quality has dropped | Review source freshness, recent prompt or configuration changes, and test results | Solution owner and CoE |

## Security information stays out of prompts

Don't paste passwords, keys, tokens, or certificates into Copilot, and treat firewall rules, Conditional Access and identity designs, network diagrams, vulnerability findings, and incident details as the organization's most restricted information. Check the organization's data classification before using AI with any of them, and use only an approved tool when the rules allow it.

## Rollback

Remove the pilot assignment, disable the affected agent, remove unnecessary access, restore the last approved configuration, document the incident, and get owner sign-off before re-enabling.

## Operating rhythm

| How often | What to review |
|---|---|
| Daily | Service health and any critical incident |
| Weekly | Adoption, support queue, and open risks |
| Monthly | Agent inventory, quality samples, and owner confirmations |
| Quarterly | Control effectiveness, accessibility, value results, and retirement decisions |

## Useful Microsoft resources

- [Microsoft Copilot release notes](https://learn.microsoft.com/en-us/copilot/microsoft-365/release-notes)
- [Message center: track upcoming changes](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/message-center)
- [Enterprise data protection in Microsoft Copilot](https://learn.microsoft.com/en-us/copilot/microsoft-365/enterprise-data-protection)
