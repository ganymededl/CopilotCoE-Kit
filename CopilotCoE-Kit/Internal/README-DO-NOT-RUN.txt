INTERNAL HELPER SCRIPTS - DO NOT RUN THESE DIRECTLY

These two scripts are called automatically:
  Prepare-CopilotCoE.ps1   by 02_Install-CopilotCoE.ps1
                              (renames Microsoft's CoE template with your values)
  Complete-CopilotCoE.ps1  by 02_Install-CopilotCoE.ps1 -SeedDemoContent
                              and by 03_Update-CoEContent.ps1
                              (publishes the starter content in ..\SeedContent)

Run only the numbered scripts in the folder above, in order:
  01_Register-CoEProvisioningApp.ps1   once, as Global Administrator
  02_Install-CopilotCoE.ps1         once, to build the CoE
  03_Update-CoEContent.ps1             whenever you change the starter content
  04_Remove-CopilotCoE.ps1          only to remove (undo) the CoE
