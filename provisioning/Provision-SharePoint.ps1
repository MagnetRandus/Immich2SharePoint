#Requires -Version 7.4
#Requires -Modules PnP.PowerShell

<#
.SYNOPSIS
Plans or applies the two-container Immich2SharePoint schema.

.DESCRIPTION
Dry-run is the default. Supply -Apply to create missing containers and fields.
Existing resources are never deleted or changed; incompatible definitions stop
the run. The script never uploads files or metadata records.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SiteUrl,

    [string]$ClientId,

    [switch]$DeviceLogin,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$photosTitle = 'Photos'
$metadataTitle = 'Photo Metadata'
$script:MissingCount = 0
$script:IncompatibleCount = 0
$script:CreatedCount = 0

function Write-Plan {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Compatible', 'Create', 'Incompatible')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Resource,

        [string]$Detail
    )

    $suffix = if ($Detail) { ": $Detail" } else { '' }
    Write-Host ("[{0}] {1}{2}" -f $Status.ToUpperInvariant(), $Resource, $suffix)
}

function New-FieldDefinition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('Text', 'Note', 'Number', 'DateTime', 'Choice', 'Boolean')][string]$Type,
        [Parameter(Mandatory)][guid]$Id,
        [int]$MaxLength = 0,
        [string[]]$Choices = @(),
        [switch]$Indexed,
        [switch]$Unique
    )

    [pscustomobject]@{
        Name       = $Name
        DisplayName = $DisplayName
        Type       = $Type
        Id         = $Id
        MaxLength  = $MaxLength
        Choices    = $Choices
        Indexed    = [bool]$Indexed
        Unique     = [bool]$Unique
    }
}

function ConvertTo-FieldXml {
    param([Parameter(Mandatory)]$Definition)

    $attributes = [ordered]@{
        Type                = $Definition.Type
        ID                  = "{$($Definition.Id)}"
        Name                = $Definition.Name
        StaticName          = $Definition.Name
        DisplayName         = $Definition.DisplayName
        Group               = 'Immich2SharePoint'
        Required            = 'FALSE'
        Indexed             = if ($Definition.Indexed) { 'TRUE' } else { 'FALSE' }
        EnforceUniqueValues = if ($Definition.Unique) { 'TRUE' } else { 'FALSE' }
    }
    if ($Definition.Type -eq 'Text' -and $Definition.MaxLength -gt 0) {
        $attributes.MaxLength = [string]$Definition.MaxLength
    }
    if ($Definition.Type -eq 'Note') {
        $attributes.RichText = 'FALSE'
        $attributes.AppendOnly = 'FALSE'
        $attributes.NumLines = '6'
    }
    if ($Definition.Type -eq 'Number') {
        $attributes.Decimals = 'Automatic'
    }
    if ($Definition.Type -eq 'DateTime') {
        $attributes.Format = 'DateTime'
    }

    $attributeText = ($attributes.GetEnumerator() | ForEach-Object {
        $escaped = [System.Security.SecurityElement]::Escape([string]$_.Value)
        '{0}="{1}"' -f $_.Key, $escaped
    }) -join ' '

    if ($Definition.Type -eq 'Choice') {
        $choiceXml = ($Definition.Choices | ForEach-Object {
            '<CHOICE>{0}</CHOICE>' -f [System.Security.SecurityElement]::Escape($_)
        }) -join ''
        return "<Field $attributeText><CHOICES>$choiceXml</CHOICES></Field>"
    }
    return "<Field $attributeText />"
}

function Get-ListOrNull {
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)]$Connection
    )

    Get-PnPList -Identity $Identity -Includes Id, Title, BaseTemplate, EnableAttachments `
        -Connection $Connection -ErrorAction SilentlyContinue
}

function Test-FieldCompatibility {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    if ([guid]$Actual.Id -ne $Expected.Id) {
        $issues.Add('field ID differs from the managed schema')
    }
    if ($Actual.TypeAsString -ne $Expected.Type) {
        $issues.Add("type is '$($Actual.TypeAsString)', expected '$($Expected.Type)'")
    }
    if ($Expected.Type -eq 'Text' -and $Expected.MaxLength -gt 0 -and
        $Actual.MaxLength -ne $Expected.MaxLength) {
        $issues.Add("maximum length is $($Actual.MaxLength), expected $($Expected.MaxLength)")
    }
    if ([bool]$Actual.Indexed -ne $Expected.Indexed) {
        $issues.Add("Indexed is $([bool]$Actual.Indexed), expected $($Expected.Indexed)")
    }
    if ([bool]$Actual.EnforceUniqueValues -ne $Expected.Unique) {
        $issues.Add("EnforceUniqueValues is $([bool]$Actual.EnforceUniqueValues), expected $($Expected.Unique)")
    }
    if ([bool]$Actual.Required) {
        $issues.Add('Required is true, expected false')
    }
    if ($Expected.Type -eq 'Choice') {
        $actualChoices = @($Actual.Choices | Sort-Object)
        $expectedChoices = @($Expected.Choices | Sort-Object)
        if (($actualChoices -join "`n") -ne ($expectedChoices -join "`n")) {
            $issues.Add('choice values differ')
        }
        if ([bool]$Actual.FillInChoice) {
            $issues.Add('fill-in choices are enabled')
        }
    }
    if ($Expected.Type -eq 'Note' -and ([bool]$Actual.RichText -or [bool]$Actual.AppendOnly)) {
        $issues.Add('multiple-lines text must be plain text and not append-only')
    }
    return $issues
}

function Ensure-Fields {
    param(
        [Parameter(Mandatory)]$List,
        [Parameter(Mandatory)][object[]]$Definitions,
        [Parameter(Mandatory)]$Connection
    )

    foreach ($definition in $Definitions) {
        $resource = "$($List.Title).$($definition.Name)"
        $actual = Get-PnPField -List $List.Id -Identity $definition.Name `
            -Connection $Connection -ErrorAction SilentlyContinue
        if ($null -eq $actual) {
            $script:MissingCount++
            if (-not $Apply) {
                Write-Plan -Status Create -Resource $resource -Detail 'missing field'
                continue
            }
            Add-PnPFieldFromXml -List $List.Id -FieldXml (ConvertTo-FieldXml $definition) `
                -Connection $Connection | Out-Null
            $script:CreatedCount++
            Write-Plan -Status Create -Resource $resource -Detail 'created'
            continue
        }

        $issues = @(Test-FieldCompatibility -Actual $actual -Expected $definition)
        if ($issues.Count -gt 0) {
            $script:IncompatibleCount++
            Write-Plan -Status Incompatible -Resource $resource -Detail ($issues -join '; ')
        }
        else {
            Write-Plan -Status Compatible -Resource $resource
        }
    }
}

function Ensure-Container {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet(100, 101)][int]$Template,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)]$Connection
    )

    $list = Get-ListOrNull -Identity $Title -Connection $Connection
    if ($null -ne $list) {
        if ([int]$list.BaseTemplate -ne $Template) {
            $script:IncompatibleCount++
            Write-Plan -Status Incompatible -Resource $Title `
                -Detail "template is $($list.BaseTemplate), expected $Template"
            return $null
        }
        Write-Plan -Status Compatible -Resource $Title
        return $list
    }

    $script:MissingCount++
    if (-not $Apply) {
        Write-Plan -Status Create -Resource $Title -Detail 'missing container'
        return $null
    }

    $templateName = if ($Template -eq 101) { 'DocumentLibrary' } else { 'GenericList' }
    New-PnPList -Title $Title -Template $templateName -Url $Url -Connection $Connection | Out-Null
    $script:CreatedCount++
    Write-Plan -Status Create -Resource $Title -Detail 'created'
    $createdList = Get-ListOrNull -Identity $Title -Connection $Connection
    if ($Template -eq 100) {
        Set-PnPList -Identity $createdList.Id -EnableAttachments $false -Connection $Connection
        Set-PnPField -List $createdList.Id -Identity 'Title' -Values @{ Required = $false } `
            -Connection $Connection | Out-Null
    }
    return Get-ListOrNull -Identity $Title -Connection $Connection
}

$photosFields = @(
    New-FieldDefinition 'I2SPContentSha256' 'Content SHA-256' Text '10000001-0000-4000-8000-000000000001' -MaxLength 64 -Indexed -Unique
    New-FieldDefinition 'I2SPSourceByteLength' 'Source Byte Length' Number '10000001-0000-4000-8000-000000000002'
    New-FieldDefinition 'I2SPAnchorImmichId' 'Anchor Immich ID' Text '10000001-0000-4000-8000-000000000003' -MaxLength 255
    New-FieldDefinition 'I2SPVerifiedUtc' 'Verified UTC' DateTime '10000001-0000-4000-8000-000000000004'
)

$metadataFields = @(
    New-FieldDefinition 'I2SPRecordKey' 'Record Key' Text '20000001-0000-4000-8000-000000000001' -MaxLength 64 -Indexed -Unique
    New-FieldDefinition 'I2SPRecordKind' 'Record Kind' Choice '20000001-0000-4000-8000-000000000002' -Choices @('Asset', 'MetadataChunk')
    New-FieldDefinition 'I2SPImmichAssetId' 'Immich Asset ID' Text '20000001-0000-4000-8000-000000000003' -MaxLength 255 -Indexed
    New-FieldDefinition 'I2SPContentSha256' 'Content SHA-256' Text '20000001-0000-4000-8000-000000000004' -MaxLength 64 -Indexed
    New-FieldDefinition 'I2SPPhotoItemId' 'Photo Item ID' Number '20000001-0000-4000-8000-000000000005'
    New-FieldDefinition 'I2SPPhotoUniqueId' 'Photo Unique ID' Text '20000001-0000-4000-8000-000000000006' -MaxLength 255
    New-FieldDefinition 'I2SPBucket' 'Bucket' Text '20000001-0000-4000-8000-000000000007' -MaxLength 255 -Indexed
    New-FieldDefinition 'I2SPOriginalFileName' 'Original File Name' Note '20000001-0000-4000-8000-000000000008'
    New-FieldDefinition 'I2SPMediaType' 'Media Type' Choice '20000001-0000-4000-8000-000000000009' -Choices @('Image', 'Video') -Indexed
    New-FieldDefinition 'I2SPDateTakenUtc' 'Date Taken UTC' DateTime '20000001-0000-4000-8000-000000000010' -Indexed
    New-FieldDefinition 'I2SPDateTakenRaw' 'Date Taken Raw' Text '20000001-0000-4000-8000-000000000011' -MaxLength 255
    New-FieldDefinition 'I2SPCameraMake' 'Camera Make' Text '20000001-0000-4000-8000-000000000012' -MaxLength 255
    New-FieldDefinition 'I2SPCameraModel' 'Camera Model' Text '20000001-0000-4000-8000-000000000013' -MaxLength 255
    New-FieldDefinition 'I2SPLensModel' 'Lens Model' Text '20000001-0000-4000-8000-000000000014' -MaxLength 255
    New-FieldDefinition 'I2SPWidth' 'Width' Number '20000001-0000-4000-8000-000000000015'
    New-FieldDefinition 'I2SPHeight' 'Height' Number '20000001-0000-4000-8000-000000000016'
    New-FieldDefinition 'I2SPDurationMs' 'Duration Milliseconds' Number '20000001-0000-4000-8000-000000000017'
    New-FieldDefinition 'I2SPGpsLatitude' 'GPS Latitude' Number '20000001-0000-4000-8000-000000000018'
    New-FieldDefinition 'I2SPGpsLongitude' 'GPS Longitude' Number '20000001-0000-4000-8000-000000000019'
    New-FieldDefinition 'I2SPGpsAltitude' 'GPS Altitude' Number '20000001-0000-4000-8000-000000000020'
    New-FieldDefinition 'I2SPCountry' 'Country' Text '20000001-0000-4000-8000-000000000021' -MaxLength 255
    New-FieldDefinition 'I2SPState' 'State' Text '20000001-0000-4000-8000-000000000022' -MaxLength 255
    New-FieldDefinition 'I2SPCity' 'City' Text '20000001-0000-4000-8000-000000000023' -MaxLength 255
    New-FieldDefinition 'I2SPDescription' 'Description' Note '20000001-0000-4000-8000-000000000024'
    New-FieldDefinition 'I2SPAlbumNames' 'Album Names' Note '20000001-0000-4000-8000-000000000025'
    New-FieldDefinition 'I2SPIsFavorite' 'Is Favorite' Boolean '20000001-0000-4000-8000-000000000026'
    New-FieldDefinition 'I2SPMetadataSha256' 'Metadata SHA-256' Text '20000001-0000-4000-8000-000000000027' -MaxLength 64
    New-FieldDefinition 'I2SPMetadataRevision' 'Metadata Revision' Text '20000001-0000-4000-8000-000000000028' -MaxLength 255
    New-FieldDefinition 'I2SPMetadataEncoding' 'Metadata Encoding' Text '20000001-0000-4000-8000-000000000029' -MaxLength 255
    New-FieldDefinition 'I2SPPayloadChunk' 'Payload Chunk' Note '20000001-0000-4000-8000-000000000030'
    New-FieldDefinition 'I2SPChunkIndex' 'Chunk Index' Number '20000001-0000-4000-8000-000000000031'
    New-FieldDefinition 'I2SPChunkCount' 'Chunk Count' Number '20000001-0000-4000-8000-000000000032'
    New-FieldDefinition 'I2SPSyncState' 'Sync State' Choice '20000001-0000-4000-8000-000000000033' -Choices @('Pending', 'Complete', 'Conflict', 'Failed', 'Overflow') -Indexed
    New-FieldDefinition 'I2SPLastSyncUtc' 'Last Sync UTC' DateTime '20000001-0000-4000-8000-000000000034'
)

$connectParameters = @{
    Url              = $SiteUrl
    ReturnConnection = $true
}
if ($ClientId) {
    $connectParameters.ClientId = $ClientId
}
if ($DeviceLogin) {
    $connectParameters.DeviceLogin = $true
}
else {
    $connectParameters.Interactive = $true
}

Write-Host ('Mode: {0}' -f $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (read-only)' }))
$connection = Connect-PnPOnline @connectParameters

try {
    $photos = Ensure-Container -Title $photosTitle -Template 101 -Url 'Photos' -Connection $connection
    $metadata = Ensure-Container -Title $metadataTitle -Template 100 -Url 'Lists/PhotoMetadata' -Connection $connection

    if ($null -ne $photos) {
        Ensure-Fields -List $photos -Definitions $photosFields -Connection $connection
    }
    elseif (-not $Apply) {
        foreach ($field in $photosFields) {
            $script:MissingCount++
            Write-Plan -Status Create -Resource "$photosTitle.$($field.Name)" -Detail 'requires missing container'
        }
    }

    if ($null -ne $metadata) {
        if ([bool]$metadata.EnableAttachments) {
            $script:IncompatibleCount++
            Write-Plan -Status Incompatible -Resource "$metadataTitle.Attachments" `
                -Detail 'attachments are enabled; this script will not change an existing setting'
        }
        $titleField = Get-PnPField -List $metadata.Id -Identity 'Title' -Connection $connection
        if ([bool]$titleField.Required) {
            $script:IncompatibleCount++
            Write-Plan -Status Incompatible -Resource "$metadataTitle.Title" `
                -Detail 'Title is required; this script will not change an existing setting'
        }
        Ensure-Fields -List $metadata -Definitions $metadataFields -Connection $connection
    }
    elseif (-not $Apply) {
        foreach ($field in $metadataFields) {
            $script:MissingCount++
            Write-Plan -Status Create -Resource "$metadataTitle.$($field.Name)" -Detail 'requires missing container'
        }
    }

    if ($null -ne $photos -and $null -ne $metadata) {
        $lookupName = 'I2SPPhotoLookup'
        $lookup = Get-PnPField -List $metadata.Id -Identity $lookupName `
            -Connection $connection -ErrorAction SilentlyContinue
        if ($null -eq $lookup) {
            $script:MissingCount++
            if ($Apply) {
                $lookupXml = '<Field Type="Lookup" ID="{20000001-0000-4000-8000-000000000035}" Name="I2SPPhotoLookup" StaticName="I2SPPhotoLookup" DisplayName="Photo" Group="Immich2SharePoint" Required="FALSE" Indexed="FALSE" EnforceUniqueValues="FALSE" List="{' + $photos.Id + '}" ShowField="I2SPContentSha256" />'
                Add-PnPFieldFromXml -List $metadata.Id -FieldXml $lookupXml `
                    -Connection $connection | Out-Null
                $script:CreatedCount++
                Write-Plan -Status Create -Resource "$metadataTitle.$lookupName" -Detail 'created'
            }
            else {
                Write-Plan -Status Create -Resource "$metadataTitle.$lookupName" -Detail 'missing lookup'
            }
        }
        else {
            $lookupIssues = [System.Collections.Generic.List[string]]::new()
            if ([guid]$lookup.Id -ne [guid]'20000001-0000-4000-8000-000000000035') {
                $lookupIssues.Add('field ID differs from the managed schema')
            }
            if ($lookup.TypeAsString -ne 'Lookup') { $lookupIssues.Add("type is '$($lookup.TypeAsString)', expected 'Lookup'") }
            if ([string]$lookup.LookupList -ne "{$($photos.Id)}" -and [string]$lookup.LookupList -ne [string]$photos.Id) {
                $lookupIssues.Add('target is not the Photos library')
            }
            if ($lookup.LookupField -ne 'I2SPContentSha256') { $lookupIssues.Add('display field is not I2SPContentSha256') }
            if ([bool]$lookup.AllowMultipleValues) { $lookupIssues.Add('lookup permits multiple values') }
            if ($lookupIssues.Count -gt 0) {
                $script:IncompatibleCount++
                Write-Plan -Status Incompatible -Resource "$metadataTitle.$lookupName" -Detail ($lookupIssues -join '; ')
            }
            else {
                Write-Plan -Status Compatible -Resource "$metadataTitle.$lookupName"
            }
        }
    }
    elseif (-not $Apply) {
        $script:MissingCount++
        Write-Plan -Status Create -Resource "$metadataTitle.I2SPPhotoLookup" -Detail 'requires both containers'
    }
}
finally {
    $connection = $null
}

Write-Host ("Summary: missing={0}, created={1}, incompatible={2}" -f `
    $script:MissingCount, $script:CreatedCount, $script:IncompatibleCount)

if ($script:IncompatibleCount -gt 0) {
    throw 'Provisioning stopped because incompatible existing resources require review.'
}

if (-not $Apply -and $script:MissingCount -gt 0) {
    Write-Host 'Dry-run only: rerun with -Apply after reviewing the plan.'
}
