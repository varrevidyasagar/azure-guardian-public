param(
    [Parameter(Mandatory = $false)]
    [string] $TargetSubscription = $null,

    [Parameter(Mandatory = $false)]
    [string] $externalCloudEnvironment = "",

    [Parameter(Mandatory = $false)]
    [string] $externalTenantId = "",

    [Parameter(Mandatory = $false)]
    [string] $externalCredentialName = ""
)

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

# get ARG exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_ARGVhdContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "argvhdexports"
}

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    $externalCredential = Get-AutomationPSCredential -Name $externalCredentialName
}

$ARGPageSize = 1000

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$cloudSuffix = ""

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    Connect-AzAccount -ServicePrincipal -EnvironmentName $externalCloudEnvironment -Tenant $externalTenantId -Credential $externalCredential 
    $cloudSuffix = $externalCloudEnvironment.ToLower() + "-"
    $cloudEnvironment = $externalCloudEnvironment   
}

$tenantId = (Get-AzContext).Tenant.Id

$alldisks = @()

Write-Output "Getting subscriptions target $TargetSubscription"
if (-not([string]::IsNullOrEmpty($TargetSubscription)))
{
    $subscriptions = $TargetSubscription
    $subscriptionSuffix = $TargetSubscription
}
else
{
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | ForEach-Object { "$($_.Id)"}
    $subscriptionSuffix = $cloudSuffix + "all-" + $tenantId
}

$mdisksTotal = @()
$resultsSoFar = 0

Write-Output "Querying for ARM Unmanaged OS Disks properties"

$argQuery = @"
resources
| where type =~ 'Microsoft.Compute/virtualMachines' and isnull(properties.storageProfile.osDisk.managedDisk)
| extend diskType = 'OS', diskCaching = tostring(properties.storageProfile.osDisk.caching), diskSize = tostring(properties.storageProfile.osDisk.diskSizeGB)
| extend vhdUriParts = split(tostring(properties.storageProfile.osDisk.vhd.uri),'/')
| extend diskStorageAccountName = tostring(split(vhdUriParts[2],'.')[0]), diskContainerName = tostring(vhdUriParts[3]), diskVhdName = tostring(vhdUriParts[4])
| order by id, diskStorageAccountName, diskContainerName, diskVhdName
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $mdisks = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $mdisks = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($mdisks -and $mdisks.GetType().Name -eq "PSResourceGraphResponse")
    {
        $mdisks = $mdisks.Data
    }
    $resultsCount = $mdisks.Count
    $resultsSoFar += $resultsCount
    $mdisksTotal += $mdisks

} while ($resultsCount -eq $ARGPageSize)

$resultsSoFar = 0

Write-Output "Found $($mdisksTotal.Count) Unmanaged OS Disk entries"

Write-Output "Querying for ARM Unmanaged Data Disks properties"

$argQuery = @"
resources
| where type =~ 'Microsoft.Compute/virtualMachines' and isnull(properties.storageProfile.osDisk.managedDisk)
| mvexpand dataDisks = properties.storageProfile.dataDisks
| extend diskType = 'Data', diskCaching = tostring(dataDisks.caching), diskSize = tostring(dataDisks.diskSizeGB)
| extend vhdUriParts = split(tostring(dataDisks.vhd.uri),'/')
| extend diskStorageAccountName = tostring(split(vhdUriParts[2],'.')[0]), diskContainerName = tostring(vhdUriParts[3]), diskVhdName = tostring(vhdUriParts[4])
| order by id, diskStorageAccountName, diskContainerName, diskVhdName
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $mdisks = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $mdisks = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($mdisks -and $mdisks.GetType().Name -eq "PSResourceGraphResponse")
    {
        $mdisks = $mdisks.Data
    }
    $resultsCount = $mdisks.Count
    $resultsSoFar += $resultsCount
    $mdisksTotal += $mdisks

} while ($resultsCount -eq $ARGPageSize)

Write-Output "Found overall $($mdisksTotal.Count) Unmanaged Disk entries"

<#
    Building CSV entries 
#>

$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")
$statusDate = $datetime.ToString("yyyy-MM-dd")

foreach ($disk in $mdisksTotal)
{
    $logentry = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $cloudEnvironment
        TenantGuid = $disk.tenantId
        SubscriptionGuid = $disk.subscriptionId
        ResourceGroupName = $disk.resourceGroup.ToLower()
        DiskName = $disk.diskVhdName.ToLower()
        InstanceId = ($disk.diskStorageAccountName + "/" + $disk.diskContainerName + "/" + $disk.diskVhdName).ToLower()
        OwnerVMId = $disk.id.ToLower()
        Location = $disk.location
        DeploymentModel = "Unmanaged"
        DiskType = $disk.diskType 
        Caching = $disk.diskCaching 
        DiskSizeGB = $disk.diskSize
        StatusDate = $statusDate
        Tags = $disk.tags
    }
    
    $alldisks += $logentry
}

<#
    Actually exporting CSV to Azure Storage
#>

$today = $datetime.ToString("yyyyMMdd")
$csvExportPath = "$today-vhds-$subscriptionSuffix.csv"

$alldisks | Export-Csv -Path $csvExportPath -NoTypeInformation

$csvBlobName = $csvExportPath

$csvProperties = @{"ContentType" = "text/csv"};

Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
