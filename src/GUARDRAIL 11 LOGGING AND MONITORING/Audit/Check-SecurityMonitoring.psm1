#Future Params:
#Security
function get-apiLinkedServicesData {
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $subscriptionId,
        [Parameter(Mandatory=$true)]
        [string]
        $resourceGroup,
        [Parameter(Mandatory=$true)]
        [string]
        $LAWName
    )
    $apiUrl="https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LAWName/linkedServices?api-version=2020-08-01"
    try {
        $response = Invoke-AzRestMethod -Uri $apiUrl -Method Get
    }
    catch {
        Write-Error "Error: Failed to call Azure Resource Manager REST API at URL '$apiURL'; returned error message: $_"
    }

    $data = $response.Content | ConvertFrom-Json
    return $data
}

function get-tenantDiagnosticsSettings {

    $apiUrl = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview"
    try {
        $response = Invoke-AzRestMethod -Uri $apiUrl -Method Get -ErrorAction Stop
    }
    catch {
        Write-Error "Error: Failed to call Azure Resource Manager REST API at URL '$apiURL'; returned error message: $_"
    }

    $data = $response.Content | ConvertFrom-Json
    return $data.value.properties
}
function get-activitylogstatus {
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $LAWResourceId
    )
    
    $subs=Get-AzSubscription -ErrorAction SilentlyContinue| Where-Object {$_.State -eq "Enabled"}
    $totalsubs=$subs.Count

    $pcount=0
    foreach ($sub in $subs) {
        $URL="https://management.azure.com/subscriptions/$($sub.Id)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview"
        
        $response = Invoke-AzRestMethod -Uri $URL -Method Get 
        
        $data = $response.Content | ConvertFrom-Json
        $configuredWSs = $data.value.Properties.workspaceId
        if ($LAWResourceId -in $configuredWSs) {
            $pcount++
        }
    }
    if ($pcount -ne $totalsubs) {
        Write-Warning "Not all subscriptions are configured to send logs to the Log Analytics Workspace"
        return $false
    }
    else {
        Write-Host "All subscriptions are configured to send logs to the Log Analytics Workspace"
        return $true
    }
}
function get-SecurityMonitoringStatus {
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $SecurityLAWResourceId,
        [Parameter(Mandatory=$true)]
        [string]
        $ControlName,
        [string] $itsginfosecmon,
        [hashtable]
        $msgTable,
        [Parameter(Mandatory=$true)]
        [string]
        $ReportTime,
        [Parameter(Mandatory=$false)]
        [string]
        $CBSSubscriptionName,
        [Parameter(Mandatory=$false)]
        [int]
        $LAWRetention=730,
        [string] 
        $CloudUsageProfiles = "3",  # Passed as a string
        [string] $ModuleProfiles,  # Passed as a string
        [switch] $EnableMultiCloudProfiles # New feature flag, default to false    
    )
    [PSCustomObject] $FinalObjectList = New-Object System.Collections.ArrayList
    [PSCustomObject] $ErrorList = New-Object System.Collections.ArrayList
    #$LogType="GuardrailsCompliance"
    #Code

    #Add test for proper right format of the LAW parameters
    $Subscription=$SecurityLAWResourceId.Split("/")[2]
    $LAWRG=$SecurityLAWResourceId.Split("/")[4]
    $LAWName=$SecurityLAWResourceId.Split("/")[8]
    
    $IsCompliant=$false
    $uncompliantParameters=6
    try{
        Select-AzSubscription -Subscription $Subscription -ErrorAction Stop | Out-Null
    }
    catch {
        $ErrorList.Add("Failed to execute the 'Select-AzSubscription' command with subscription ID '$($subscription)'--`
            ensure you have permissions to the subscription, the ID is correct, and that it exists in this tenant; returned `
            error message: $_")
        #    ensure you have permissions to the subscription, the ID is correct, and that it exists in this tenant; returned `
        #    error message: $_"
        throw "Error: Failed to execute the 'Select-AzSubscription' command with subscription ID '$($subscription)'--ensure `
            you have permissions to the subscription, the ID is correct, and that it exists in this tenant; returned error message: $_"
    }

    try {
        $LAW=Get-AzOperationalInsightsWorkspace -Name $LAWName -ResourceGroupName $LAWRG -ErrorAction Stop
    }
    catch {
        $ErrorList.Add("Failed to retrieve Log Analytics workspace '$LAWName' from resource group '$LAWRG'--verify that the `
        workspace exists and that permissions are sufficient; returned error message: $_")
        #    workspace exists and that permissions are sufficient; returned error message: $_"
    }
    if ($null -eq $LAW)
    {
        $IsCompliant=$false
        $Comments=$msgTable.securityLAWNotFound
    }
    else {
        # 1 - Test linked automation account
        $LinkedServices=get-apiLinkedServicesData -subscriptionId $Subscription `
            -resourceGroup $LAWRG `
            -LAWName $LAWName
        if (($LinkedServices.value.properties.resourceId | Where-Object {$_ -match "automationAccounts"}).count -gt 0)
        {
            $uncompliantParameters--
            Write-Verbose "1 is good."
        }
        else {
            $Comments+=$msgTable.lawNoAutoAcct
        }
        # 2 -Test Retention Days
        $Retention=$LAW.retentionInDays
        if ($Retention -ge $LAWRetention)
        {
            $uncompliantParameters--
            Write-Verbose "2 is good."
        }
        else {
            $Comments+=$msgTable.lawRetentionSecDays -f $LAWRetention
        }
        # 3
        if (get-activitylogstatus -LAWResourceId $LAW.ResourceId) {
            $uncompliantParameters--
            Write-Verbose "3 is good."
        }
        else {
            $Comments+=$msgTable.lawNoActivityLogs<# Action when all if and elseif conditions are false #>
        }
        # 4 - Tests for required Solutions
        $enabledSolutions=(Get-AzOperationalInsightsIntelligencePack -ResourceGroupName $LAW.ResourceGroupName -WorkspaceName $LAW.Name| Where-Object {$_.Enabled -eq "True"}).Name
        if ($enabledSolutions -contains "Updates" -and $enabledSolutions -contains "AntiMalware")
        {
            $uncompliantParameters--
            Write-Verbose "4 is good."
        }
        else {
            $Comments+=$msgTable.lawSolutionNotFound
        }
        # 5 - Tenant Diagnostics configuration. Needs Graph API...
        $tenantWS=get-tenantDiagnosticsSettings
        if ($SecurityLAWResourceId -in $tenantWS.workspaceId)
        {
            $uncompliantParameters--
            Write-Verbose "5 is good."
        }
        else {
            $Comments+=$msgTable.lawNoTenantDiag
        }
        # 6 - Workspace is there but need to check if logs are enabled.
        $enabledLogs=(($tenantWS| Where-Object {$_.workspaceId -eq $SecurityLAWResourceId}).logs | Where-Object {$_.enabled -eq $true}).category
        if ("AuditLogs" -in $enabledLogs -and "SignInLogs" -in $enabledLogs)
        {
            $uncompliantParameters--
            Write-Verbose "6 is good."
        }
        else {
            $Comments+=$msgTable.lawMissingLogTypes
        }
        #Blueprint redirection
        # Sentinel, not sure how to detect this.
        if ($uncompliantParameters -eq 0)
        {
            $IsCompliant=$true
            $Comments= $msgTable.logsAndMonitoringCompliantForSecurity
        }
        else {
            $IsCompliant=$false #Not compliant
        }
        Write-Verbose "Found $($uncompliantParameters) non-compliant parameters."
        $object = [PSCustomObject]@{ 
            ComplianceStatus = $IsCompliant
            Comments = $Comments
            ItemName = $msgTable.securityMonitoring
            itsgcode = $itsginfosecmon
            ControlName = $ControlName
            ReportTime = $ReportTime
        }
        if ($EnableMultiCloudProfiles) {        
            $evalResult = Get-EvaluationProfile -CloudUsageProfiles $CloudUsageProfiles -ModuleProfiles $ModuleProfiles -SubscriptionId $Subscription
            if (!$evalResult.ShouldEvaluate) {
                if ($evalResult.Profile -gt 0) {
                    $object.ComplianceStatus = "Not Applicable"
                    $object | Add-Member -MemberType NoteProperty -Name "Profile" -Value $evalResult.Profile
                    $object.Comments = "Not evaluated - Profile $($evalResult.Profile) not present in CloudUsageProfiles"
                } else {
                    $ErrorList.Add("Error occurred while evaluating profile configuration")
                }
            } else {
                
                $object | Add-Member -MemberType NoteProperty -Name "Profile" -Value $evalResult.Profile
            }
        }    

        $FinalObjectList+=$object
        $IsCompliant=$true
    }

    $moduleOutput= [PSCustomObject]@{ 
        ComplianceResults = $FinalObjectList 
        Errors=$ErrorList
        AdditionalResults = $AdditionalResults
    }
    return $moduleOutput
}
