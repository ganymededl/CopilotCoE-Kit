# Data protection
> Protect government information before using Copilot or publishing an agent. These examples are not adopted agency policy.

## Start with the data and its owner

| Example data level | Examples | Starter AI guidance |
|---|---|---|
| Low (public) | Published reports, public notices and general service guidance | Use only agency-approved tools; check accuracy and ownership |
| Moderate (not public) | Administrative drafts and operational planning | Use an approved work-account experience only when the agency and data owner permit it |
| High (protected or regulated) | Residents' personal information, case files, health, tax, criminal justice, financial and personnel records | No use without explicit agency authorization for that information and purpose |

These are starter examples of Low / Moderate / High, not adopted labels for every agency. Map them to {{Link:AIGuidelines|your agency's AI and data-classification rules}}. If that route is not configured, ask the data owner; this page grants no exception.

## Controls to check

1. **Permissions and oversharing.** Copilot respects existing access but makes overbroad access easier to discover. Review site membership, links, source owners and search/discovery controls.
2. **Sensitivity labels.** Publish only approved labels and encryption rules. Test the labeled content in the intended cloud and Copilot experience.
3. **Data loss prevention.** Security owners choose and test Purview DLP for Copilot and agents; starter guidance is not a deployed policy. Check supported locations and GCC-specific behavior.
4. **Monitoring and public records.** Assign an authorized audit owner, records officer and retention schedule. Keep sensitive prompts and agent test evidence out of public lists.
5. **Agents and builders.** Review sources, connectors, actions, environment, billing and reader permissions. A Showcase listing is not IT approval or a grant to source data.

IT's separate operational checklist is [Data readiness for IT](Guide-Data-Readiness-for-IT.aspx). See [Agent lifecycle and approval](Agent-Lifecycle-and-Approval.aspx).

**Data or safety concern?** {{Link:DataSafetyIncident|Report a data or safety incident}} through the configured route, not general feedback. If no route is configured, ask for the approved route without sending sensitive information.

Microsoft guidance: [Purview protection for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/purview/ai-m365-copilot) and [secure, governed data foundation](https://learn.microsoft.com/en-us/microsoft-365/copilot/configure-secure-governed-data-foundation-microsoft-365-copilot).
