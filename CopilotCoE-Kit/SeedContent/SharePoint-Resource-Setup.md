# SharePoint resource setup: calendar, FAQ, feedback, and champion directory

**For an administrator building the CoE in a new tenant.** The included entries and pages are editable examples, not approved events, policies, contacts, or institutional decisions.

## Training calendar

1. Use the supplied completion script to create a SharePoint **Events-template** list named `Copilot Training Calendar` at `Lists/CopilotTrainingCalendar`. For a manual build, use Site contents > New > App > classic experience > Calendar where available. A modern blank/CSV list is not interchangeable with the Events list required by the landing-page Events web part.
2. Retain the built-in `Title`, `EventDate` (start), `EndDate`, `Description`, and `Location` columns.
3. Set the site's regional time zone to Eastern Time. The script converts the CSV's Eastern times to UTC, including the November daylight-saving transition.
4. Add `Audience` (single line of text), `Format` (Choice), and `Sample status` (Choice). Add a `Registration link` (Hyperlink) if using real registration.
5. Seed the existing Events list with `Training-Calendar.csv` using the completion script, or enter the six records manually. Do not create a second list with **From CSV**. Check every rendered start/end time.
6. Create a Calendar view using `EventDate` and `EndDate`. Keep a list view for accessible, screen-reader-friendly browsing.
7. Edit TrainingHome. Point the **Training calendar** Resources card to that calendar view, and edit **Learning Series** to use this site's `Copilot Training Calendar` list rather than the original empty Events list. Publish and confirm actual event cards appear.
8. Replace every DRAFT status, confirm facilitator, meeting location/link, accessibility, and registration method before inviting anyone. Delete or move expired examples after the sample period.

The six included sample sessions are dated October 14 and 28, November 4 and 18, and December 2 and 16, 2026 (Eastern Time). They are examples only; no facilitator, calendar booking, or real {{OrgShort}} session is assigned.

## FAQs

Create or edit a SharePoint page named `Copilot-FAQs.aspx`, add the content in `Copilot-FAQs.md`, and publish it after the policy owners approve local wording. Point the **FAQs** card to that page. Keep Microsoft product documentation as a separate source link and recheck it periodically.

## Feedback

Create a page named `Give-Feedback.aspx` with the supplied setup guide and a prominent link to the existing Ask Us Anything channel. For actual collection, choose an approved Forms or Lists design and configure who can see responses, whether identities are recorded, retention, and escalation. A public channel/list is not confidential. Keep the seeded sample marked as demonstration data.

## Champions

Use the `Meet-your-Champions.aspx` page for the introduction, approved champion profiles, and embedded department directory. The left-navigation item **Department Champions** should open that page; the backing `Department Champions` list contains department, primary and backup people, approved contact link, expertise, office hours, status, directory owner, and last-verified date. Confirm each appointment and publication permission. The `Champion-Profile-Template.md` is not a real profile; do not use invented names, photos, contacts, or office hours.

## Governance policy sample

Store `Higher-Ed-AI-Governance-Framework-DRAFT.md` in the restricted Leadership Governance area under `03-Policy-and-Risk-Decisions`. Keep the draft/not-approved label intact. Local stakeholders must review and approve policy before any production use; do not publish a sample governance draft as current policy.
