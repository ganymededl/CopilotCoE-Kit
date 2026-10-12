ORGANIZATION PROMPTS (Content\OrgPrompts) - OPTIONAL

The site's Copilot Prompt Library list starts with the base prompts for this environment:
  Higher education (kit default)   SeedContent\OrgPrompts\highered_prompt_library_1..3_of_3.csv
  Government (Government pack)     gcc_prompt_library_import_1..3_of_3.csv (the pack blanks the higher-ed files)

Leave this folder empty to use only the base prompts. To add your organization's own prompts, put CSV
files here in the Microsoft 365 admin center import format - the same files you upload in
Copilot > Prompts > Import:
  Title,Description,Display Prompt,Prompt Text,Products,Department,Task Type,Locale
  UTF-8, at most 100 prompts per file; Title <= 35, Display Prompt <= 132, Description <= 200,
  Department <= 120, Prompt Text <= 8,000 characters; Task Type from the supported list.

  Add      a CSV with a new file name is added to the base prompts
  Replace  a CSV with the same name as a base file replaces that file
  Remove   an empty file with a base file's name leaves that base file out

The kit never changes these files and leaves {{placeholders}} in prompts for the person using them.
Titles must be unique (per locale) across all files. Prompts from these files are added approved;
prompts people add on the site wait for a catalog reviewer. Existing list rows are never changed on
a rerun. Set "PromptLibrary": "Off" in Deployment-Settings.json to leave the list out.
Files named README* are not read.
