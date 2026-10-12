# Copilot feedback: starter setup

**Sample setup guidance.** The sample row in the feedback list is illustrative, not a real user submission. Do not use this public demonstration list for confidential, sensitive, student, or personnel information.

## Feedback route for CoE visitors

1. Open the **Give Feedback** card on TrainingHome.
2. Read the notice on the Feedback page.
3. Choose **Open Ask Us Anything in Teams** to share non-sensitive feedback with the CoE community.
4. For ordinary access problems, use the {{Link:ServiceDesk|IT service desk}}. For data or safety concerns, use the separate {{Link:DataSafetyIncident|Report a data or safety incident}} route instead. Stop using affected content and never post sensitive details in Teams, general feedback or email.

If a route is **not configured**, this page has not supplied that endpoint and does not submit a report. Use an existing approved organizational route if known, or ask for the correct route without sharing sensitive details.

The Teams link opens the existing Ask Us Anything channel; it does not send a message automatically.

## SharePoint list setup for a new tenant

1. Create a SharePoint **Microsoft Lists** list named `Copilot Feedback` on the CoE parent site.
2. Keep the built-in **Title** column and rename its display name to `What did you try or request?`.
3. Add `Category` as a Choice column: `Useful`, `Needs improvement`, `Training request`, `Resource request`, `Other`.
4. Add `Workflow or task` as a single-line text column.
5. Add `Feedback details` as multiple lines of text.
6. Add `Department` as an optional single-line text column.
7. Add `Follow-up requested` as a Choice column (`Yes`, `No`).
8. Add `Demonstration sample` as a Yes/No column; mark seeded examples Yes.
9. Configure list permissions deliberately. The sample implementation is readable by CoE members; do not assume a standard list is private per submitter.
10. Add a Feedback page with a clear privacy notice and a link to the list or an institution-approved Microsoft Form. Add the page URL to the TrainingHome Resources card.

Before collecting real feedback, decide who can see responses, whether submitter identity is collected, how long records are retained, how requests are triaged, and which channel handles sensitive reports. If submitters need confidentiality, do not use a broadly readable list or public Teams channel; have the institution configure an approved form and response-access model.
