# Governance and Responsible AI
> Your organization's official AI guidance in one place, with how Copilot fits within it.

**Data or safety concern?** {{Link:DataSafetyIncident|Report a data or safety incident}}. Stop using the affected content and do not copy or share it. Do not post sensitive details in Teams, general feedback or email.{{IfRouteMissing:DataSafetyIncident| If the link says **route not configured**, this site has not supplied an incident endpoint: use an existing approved organizational incident route if you know it, or ask for the correct route without sharing sensitive details.}}

## Official documents for the {{OrgNoun}}

Documents published by {{OrgName}} are the authoritative source. Documents hosted in this channel's **Official Documents** folder:

{{HostedFiles}}

{{LinkList:GovernanceLinks}}

## Which data can go into which AI tool

Use your organization's data classification policy and {{Link:AIGuidelines|AI guidelines}}.{{IfRouteMissing:AIGuidelines| If a route is not configured, these starter examples do not authorize data use; confirm the applicable policy before using non-public information.}}

| Data level | Examples | Typical AI guidance (confirm with your organization) |
|---|---|---|
| Public | Published web pages, catalog descriptions, public announcements | Any approved tool |
| Internal | Planning and administrative data for internal use | Enterprise tools with work account sign-in only, after review |
| Not public or regulated | Residents' personal information, case files, health, tax, criminal justice, financial, or personnel data protected by law or contract | Only where your organization has explicitly approved the tool and use |

## How the CoE classifies Copilot uses (risk tiers)

| Tier | Examples | Required before use |
|---|---|---|
| 1 - Assistive | Drafting, summarizing, and searching with a person reviewing the result | Standard guidance on this page and in the Copilot guides |
| 2 - Operational | Agents or workflows that assist a service using approved data, with monitored output | CoE review, named owner, test plan, pilot group (see the Copilot operations guide) |
| 3 - Consequential | Anything that affects decisions about people, eligibility, enforcement, finances, or regulated data | Documented human approval, security and data-owner sign-off, evaluation evidence, leadership approval |

## Who is accountable (sample RACI)

| Activity | IT platform owner | Security | Data owners | Champions | Service desk |
|---|---|---|---|---|---|
| Platform configuration and roadmap | A | C | C | I | I |
| Security baseline and compliance controls | C | A | C | I | I |
| Data readiness and access review | C | C | A | I | I |
| Adoption, training, and feedback | A | I | C | R | C |
| First-line support and escalation | A | C | I | I | R |

R = Responsible, A = Accountable, C = Consulted, I = Informed. Replace the role names with your organization's actual owners.

## Copilot quick reference

- **Sign in with your work account** so enterprise data protection applies.
- **Disclose AI help.** Say which tool you used and that a person reviewed the output. See the {{Link:AIGuidelines|AI guidelines}} for the expected wording.
- **Check before you share.** Copilot can be wrong. Verify facts, numbers, citations, and tone.
- **Ask before you buy or install** another AI tool; use the {{Link:TechnologyRequest|technology request process}}. A missing route is not approval to proceed.
- **Public records:** Copilot prompts, responses, and drafts may be government data. Follow your records-retention and data practices rules.

## Where governance work happens

- **This page and channel** publish approved guidance to everyone.
- **Leadership Governance** and **Program Governance** are restricted shared channels where drafts are prepared before approval.

## Microsoft resources

- [Enterprise data protection in Microsoft Copilot and Copilot Chat](https://learn.microsoft.com/en-us/copilot/microsoft-365/enterprise-data-protection)
- [Microsoft Responsible AI principles](https://www.microsoft.com/en-us/ai/responsible-ai)
