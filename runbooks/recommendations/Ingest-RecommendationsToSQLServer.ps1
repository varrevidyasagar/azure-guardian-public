$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

$sqlserver = Get-AutomationVariable -Name  "AzureOptimization_SQLServerHostname"
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization_SQLServerCredential"
$SqlUsername = $sqlserverCredential.UserName 
$SqlPass = $sqlserverCredential.GetNetworkCredential().Password 
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization_SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}
$ChunkSize = [int] (Get-AutomationVariable -Name  "AzureOptimization_SQLServerInsertSize" -ErrorAction SilentlyContinue)
if (-not($ChunkSize -gt 0))
{
    $ChunkSize = 900
}
$SqlTimeout = 120

$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_RecommendationsContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer)) {
    $storageAccountSinkContainer = "recommendationsexports"
}
$StorageBlobsPageSize = [int] (Get-AutomationVariable -Name  "AzureOptimization_StorageBlobsPageSize" -ErrorAction SilentlyContinue)
if (-not($StorageBlobsPageSize -gt 0))
{
    $StorageBlobsPageSize = 1000
}

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
    "User" { 
        $cred = Get-AutomationPSCredential –Name $authenticationCredential
        Connect-AzAccount -Credential $cred -EnvironmentName $cloudEnvironment
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

# get reference to storage sink
Write-Output "Getting reference to $storageAccountSink storage account (recommendations exports sink)"
Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$allblobs = @()

Write-Output "Getting blobs list..."
$continuationToken = $null
do
{
    $blobs = Get-AzStorageBlob -Container $storageAccountSinkContainer -MaxCount $StorageBlobsPageSize -ContinuationToken $continuationToken -Context $sa.Context | Sort-Object -Property LastModified
    if ($blobs.Count -le 0) { break }
    $allblobs += $blobs
    $continuationToken = $blobs[$blobs.Count -1].ContinuationToken;
}
While ($null -ne $continuationToken)

$SqlServerIngestControlTable = "SqlServerIngestControl"
$recommendationsTable = "Recommendations"

$tries = 0
$connectionSuccess = $false

do {
    $tries++
    try {
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
        $Conn.Open() 
        $Cmd=new-object system.Data.SqlClient.SqlCommand
        $Cmd.Connection = $Conn
        $Cmd.CommandTimeout = $SqlTimeout
        $Cmd.CommandText = "SELECT * FROM [dbo].[$SqlServerIngestControlTable] WHERE StorageContainerName = '$storageAccountSinkContainer' and SqlTableName = '$recommendationsTable'"
    
        $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $sqlAdapter.SelectCommand = $Cmd
        $controlRows = New-Object System.Data.DataTable
        $sqlAdapter.Fill($controlRows) | Out-Null            
        $connectionSuccess = $true
    }
    catch {
        Write-Output "Failed to contact SQL at try $tries."
        Write-Output $Error[0]
        Start-Sleep -Seconds ($tries * 20)
    }    
} while (-not($connectionSuccess) -and $tries -lt 3)

if (-not($connectionSuccess))
{
    throw "Could not establish connection to SQL."
}

if ($controlRows.Count -eq 0)
{
    throw "Could not find a control row for $storageAccountSinkContainer container and $recommendationsTable table."
}

$controlRow = $controlRows[0]    
$lastProcessedLine = $controlRow.LastProcessedLine
$lastProcessedDateTime = $controlRow.LastProcessedDateTime.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")

$Conn.Close()    
$Conn.Dispose()            

$newProcessedTime = $null

$unprocessedBlobs = @()

foreach ($blob in $allblobs) {
    if ($lastProcessedDateTime -lt $blob.LastModified.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")) {
        $unprocessedBlobs += $blob
    }
}

$unprocessedBlobs = $unprocessedBlobs | Sort-Object -Property LastModified

Write-Output "Found $($unprocessedBlobs.Count) new blobs to process..."

foreach ($blob in $unprocessedBlobs) {
    $newProcessedTime = $blob.LastModified.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
    Write-Output "About to process $($blob.Name)..."
    Get-AzStorageBlobContent -CloudBlob $blob.ICloudBlob -Context $sa.Context -Force
    $jsonObject = Get-Content -Path $blob.Name | ConvertFrom-Json
    Write-Output "Blob contains $($jsonObject.Count) results..."

    if ($null -eq $jsonObject)
    {
        $recCount = 0
    }
    elseif ($null -eq $jsonObject.Count)
    {
        $recCount = 1
    }
    else
    {
        $recCount = $jsonObject.Count    
    }

    $linesProcessed = 0
    $jsonObjectSplitted = @()

    if ($recCount -gt 1)
    {
        for ($i = 0; $i -lt $recCount; $i += $ChunkSize) {
            $jsonObjectSplitted += , @($jsonObject[$i..($i + ($ChunkSize - 1))]);
        }
    }
    else
    {
        $jsonObjectArray = @()
        $jsonObjectArray += $jsonObject
        $jsonObjectSplitted += , $jsonObjectArray   
    }
    
    for ($j = 0; $j -lt $jsonObjectSplitted.Count; $j++)
    {
        if ($jsonObjectSplitted[$j])
        {
            $currentObjectLines = $jsonObjectSplitted[$j].Count
            if ($lastProcessedLine -lt $linesProcessed)
            {
                $sqlStatement = "INSERT INTO [$recommendationsTable]"
                $sqlStatement += " (RecommendationId, GeneratedDate, Cloud, Category, ImpactedArea, Impact, RecommendationType, RecommendationSubType,"
                $sqlStatement += " RecommendationSubTypeId, RecommendationDescription, RecommendationAction, InstanceId, InstanceName, AdditionalInfo,"
                $sqlStatement += " ResourceGroup, SubscriptionGuid, SubscriptionName, TenantGuid, FitScore, Tags, DetailsUrl) VALUES"
                for ($i = 0; $i -lt $jsonObjectSplitted[$j].Count; $i++)
                {
                    $jsonObjectSplitted[$j][$i].RecommendationDescription = $jsonObjectSplitted[$j][$i].RecommendationDescription.Replace("'", "")
                    $jsonObjectSplitted[$j][$i].RecommendationAction = $jsonObjectSplitted[$j][$i].RecommendationAction.Replace("'", "")            
                    $additionalInfoString = $jsonObjectSplitted[$j][$i].AdditionalInfo | ConvertTo-Json
                    $tagsString = $jsonObjectSplitted[$j][$i].Tags | ConvertTo-Json
                    $subscriptionGuid = "NULL"
                    if ($jsonObjectSplitted[$j][$i].SubscriptionGuid)
                    {
                        $subscriptionGuid = "'$($jsonObjectSplitted[$j][$i].SubscriptionGuid)'"
                    }
                    $subscriptionName = "NULL"
                    if ($jsonObjectSplitted[$j][$i].SubscriptionName)
                    {
                        $subscriptionName = "'$($jsonObjectSplitted[$j][$i].SubscriptionName)'"
                    }
                    $resourceGroup = "NULL"
                    if ($jsonObjectSplitted[$j][$i].ResourceGroup)
                    {
                        $resourceGroup = "'$($jsonObjectSplitted[$j][$i].ResourceGroup)'"
                    }
                    $sqlStatement += " (NEWID(), CONVERT(DATETIME, '$($jsonObjectSplitted[$j][$i].Timestamp)'), '$($jsonObjectSplitted[$j][$i].Cloud)'"
                    $sqlStatement += ", '$($jsonObjectSplitted[$j][$i].Category)', '$($jsonObjectSplitted[$j][$i].ImpactedArea)'"
                    $sqlStatement += ", '$($jsonObjectSplitted[$j][$i].Impact)', '$($jsonObjectSplitted[$j][$i].RecommendationType)'"
                    $sqlStatement += ", '$($jsonObjectSplitted[$j][$i].RecommendationSubType)', '$($jsonObjectSplitted[$j][$i].RecommendationSubTypeId)'"
                    $sqlStatement += ", '$($jsonObjectSplitted[$j][$i].RecommendationDescription)', '$($jsonObjectSplitted[$j][$i].RecommendationAction)'"
                    $sqlStatement += ", '$($jsonObjectSplitted[$j][$i].InstanceId)', '$($jsonObjectSplitted[$j][$i].InstanceName)', '$additionalInfoString'"
                    $sqlStatement += ", $resourceGroup, $subscriptionGuid, $subscriptionName, '$($jsonObjectSplitted[$j][$i].TenantGuid)'"
                    $sqlStatement += ", $($jsonObjectSplitted[$j][$i].FitScore), '$tagsString', '$($jsonObjectSplitted[$j][$i].DetailsURL)')"
                    if ($i -ne ($jsonObjectSplitted[$j].Count-1))
                    {
                        $sqlStatement += ","
                    }
                }
        
                $Conn2 = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
                $Conn2.Open() 
        
                $Cmd=new-object system.Data.SqlClient.SqlCommand
                $Cmd.Connection = $Conn2
                $Cmd.CommandText = $sqlStatement
                $Cmd.CommandTimeout=120 
                try
                {
                    $Cmd.ExecuteReader()
                }
                catch
                {
                    Write-Output "Failed statement: $sqlStatement"
                    throw
                }
        
                $Conn2.Close()                
            
                $linesProcessed += $currentObjectLines
                Write-Output "Processed $linesProcessed lines..."
                if ($j -eq ($jsonObjectSplitted.Count - 1)) {
                    $lastProcessedLine = -1    
                }
                else {
                    $lastProcessedLine = $linesProcessed - 1   
                }
            
                $updatedLastProcessedLine = $lastProcessedLine
                $updatedLastProcessedDateTime = $lastProcessedDateTime
                if ($j -eq ($jsonObjectSplitted.Count - 1)) {
                    $updatedLastProcessedDateTime = $newProcessedTime
                }
                $lastProcessedDateTime = $updatedLastProcessedDateTime
                Write-Output "Updating last processed time / line to $($updatedLastProcessedDateTime) / $updatedLastProcessedLine"
                $sqlStatement = "UPDATE [$SqlServerIngestControlTable] SET LastProcessedLine = $updatedLastProcessedLine, LastProcessedDateTime = '$updatedLastProcessedDateTime' WHERE StorageContainerName = '$storageAccountSinkContainer'"
                $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
                $Conn.Open() 
                $Cmd=new-object system.Data.SqlClient.SqlCommand
                $Cmd.Connection = $Conn
                $Cmd.CommandText = $sqlStatement
                $Cmd.CommandTimeout=$SqlTimeout 
                $Cmd.ExecuteReader()
                $Conn.Close()
            }
            else
            {
                $linesProcessed += $currentObjectLines  
            }        
        }
    }
}