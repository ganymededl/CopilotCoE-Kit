function New-CoEWordBrowserUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][guid]$FileId
    )
    $site = $null
    if (-not [uri]::TryCreate($SiteUrl, [UriKind]::Absolute, [ref]$site) -or
        $site.Scheme -ne "https" -or $site.UserInfo -or $site.Query -or $site.Fragment -or
        $FileId -eq [guid]::Empty) {
        throw "A verified HTTPS site URL and nonempty document ID are required for a Word link."
    }
    $sourceDoc = [uri]::EscapeDataString("{$($FileId.ToString('D'))}")
    return "$($site.AbsoluteUri.TrimEnd('/'))/_layouts/15/Doc.aspx?sourcedoc=$sourceDoc&action=default"
}

function Get-CoEWordBrowserUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][string]$FilePath
    )
    $file = Get-PnPFile -Url $FilePath -AsFileObject -Connection $Connection -ErrorAction Stop
    $null = Get-PnPProperty -ClientObject $file -Property UniqueId,ServerRelativeUrl,Exists,Name `
        -Connection $Connection -ErrorAction Stop
    $prefix = [uri]::UnescapeDataString(([uri]$SiteUrl).AbsolutePath).TrimEnd("/") + "/"
    $path = [uri]::UnescapeDataString([string]$file.ServerRelativeUrl)
    if (-not $file.Exists -or $file.Name -notlike "*.docx" -or
        -not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The Word document '$FilePath' was not verified beneath the intended governance site."
    }
    New-CoEWordBrowserUrl -SiteUrl $SiteUrl -FileId $file.UniqueId
}

function New-CoEWordBrowserAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Label
    )
    $href = [Net.WebUtility]::HtmlEncode($Url)
    $text = [Net.WebUtility]::HtmlEncode($Label)
    return "<a href='$href' target='_blank' rel='noopener noreferrer' data-interception='off'>$text</a>"
}
