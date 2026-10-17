Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\GovernanceLinks.ps1")

function Get-PnPFile {
    [CmdletBinding()]
    param($Url, [switch]$AsFileObject, $Connection)
    throw "Unmocked governance file metadata read"
}
function Get-PnPProperty {
    [CmdletBinding()]
    param($ClientObject, $Property, $Connection)
    throw "Unmocked governance file property read"
}

Describe "Word opening links without document downloads" {
    It "uses the document ID in a site-scoped Word-opening page" {
        New-CoEWordBrowserUrl -SiteUrl "https://example.sharepoint.com/sites/Leadership/" `
            -FileId "11111111-2222-3333-4444-555555555555" |
            Should Be "https://example.sharepoint.com/sites/Leadership/_layouts/15/Doc.aspx?sourcedoc=%7B11111111-2222-3333-4444-555555555555%7D&action=default"
    }
    It "rejects unsafe or ambiguous site URLs and empty document IDs" {
        foreach ($url in @("http://example.org/site", "relative/site", "https://example.org/site?x=1",
            "https://example.org/site#part", "https://user@example.org/site")) {
            { New-CoEWordBrowserUrl -SiteUrl $url -FileId "11111111-2222-3333-4444-555555555555" } | Should Throw
        }
        { New-CoEWordBrowserUrl -SiteUrl "https://example.org/site" -FileId ([guid]::Empty) } | Should Throw
    }
    It "escapes label and query and opens outside the Teams frame" {
        $html = New-CoEWordBrowserAnchor -Url "https://example.org/Doc.aspx?sourcedoc=1&action=default" `
            -Label "Policy & owner's <review>"
        $html | Should Match "sourcedoc=1&amp;action=default"
        $html | Should Match "Policy &amp; owner&#39;s &lt;review&gt;"
        $html | Should Match "target='_blank'"
        $html | Should Match "rel='noopener noreferrer'"
        $html | Should Match "data-interception='off'"
    }
    It "reads only file metadata and verifies the intended governance site" {
        Mock Get-PnPFile { [pscustomobject]@{ Exists = $true; Name = "Policy.docx"
            UniqueId = "11111111-2222-3333-4444-555555555555"
            ServerRelativeUrl = "/sites/Leadership/Shared Documents/Policy.docx" } }
        Mock Get-PnPProperty {}
        Get-CoEWordBrowserUrl -Connection offline -SiteUrl "https://example.sharepoint.com/sites/Leadership" `
            -FilePath "Shared Documents/Policy.docx" | Should Match "/sites/Leadership/_layouts/15/Doc.aspx"
        Assert-MockCalled Get-PnPFile -Times 1 -Exactly -Scope It -ParameterFilter { $AsFileObject }
    }
    It "refuses missing, non-Word or outside-site files rather than rendering broken links" {
        Mock Get-PnPProperty {}
        foreach ($file in @(
            [pscustomobject]@{ Exists = $false; Name = "Policy.docx"; UniqueId = [guid]::NewGuid()
                ServerRelativeUrl = "/sites/Leadership/Shared Documents/Policy.docx" },
            [pscustomobject]@{ Exists = $true; Name = "Policy.pdf"; UniqueId = [guid]::NewGuid()
                ServerRelativeUrl = "/sites/Leadership/Shared Documents/Policy.pdf" },
            [pscustomobject]@{ Exists = $true; Name = "Policy.docx"; UniqueId = [guid]::NewGuid()
                ServerRelativeUrl = "/sites/Another/Shared Documents/Policy.docx" })) {
            $script:testFile = $file
            Mock Get-PnPFile { $script:testFile }
            { Get-CoEWordBrowserUrl -Connection offline -SiteUrl "https://example.sharepoint.com/sites/Leadership" `
                -FilePath "Shared Documents/Policy.docx" } | Should Throw "not verified"
        }
    }
    It "propagates denied metadata access" {
        Mock Get-PnPFile { throw "403 document access denied" }
        { Get-CoEWordBrowserUrl -Connection offline -SiteUrl "https://example.sharepoint.com/sites/Leadership" `
            -FilePath "Shared Documents/Policy.docx" } | Should Throw "403"
    }
}
