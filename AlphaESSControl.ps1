

# Check if the script is running in Azure Runbook or locally
if ($env:AZUREPS_HOST_ENVIRONMENT) { 
    
    "Running in Azure Runbook" 
    Import-Module Az.Storage

    # CONFIGURATION
    $storageAccountName = "bbphotostorage"
    $containerName = "alphaess"
    
    Connect-AzAccount -Identity

    # Create a storage context bound to the connected account (Azure AD)
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

    # Download blobs to local files
    $out=Get-AzStorageBlobContent -Container $containerName -Blob "AlphaESSControlConfig.xml" -Destination "AlphaESSControlConfig.xml" -Context $ctx -Force
    $out=Get-AzStorageBlobContent -Container $containerName -Blob "usage.txt" -Destination "usage.txt" -Context $ctx -Force

} else { 
    "Running locally on Windows" 
}


# load the config files
[xml]$AlphaESSControlConfig = Get-Content -Path "AlphaESSControlConfig.xml"
$usage = Import-Csv ".\usage.txt" -Delimiter ","


$AlphaESSControl = $AlphaESSControlConfig.AlphaESSControlConfig.controlSettings
$AlphaESSSettings = $AlphaESSControlConfig.AlphaESSControlConfig.alphaEssSettings
$HAWebhook = $AlphaESSControlConfig.AlphaESSControlConfig.homeAssistantSettings.homeAssistantWebhook
$PVsettings = $AlphaESSControlConfig.AlphaESSControlConfig.PVSettings

$utcNow = (Get-Date).ToUniversalTime()
$cetZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Central European Standard Time")
$datetimeCET = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $cetZone)



# FUNCTIONS
# Fetch EPEX Spot Prices 
function Get-EpexPrices {
    
    
    $today = get-date $datetimeCET -Format "yyyy-MM-dd"
    $tomorrow = get-date (get-date $datetimeCET).AddDays(1) -Format "yyyy-MM-dd"

    $prices = ((Invoke-WebRequest -UseBasicParsing -Uri "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?market=DayAhead&deliveryArea=BE&currency=EUR&date=$today").content | ConvertFrom-Json).multiAreaEntries
    $prices += ((Invoke-WebRequest -UseBasicParsing -Uri "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?market=DayAhead&deliveryArea=BE&currency=EUR&date=$tomorrow").content | ConvertFrom-Json).multiAreaEntries
    
    $pricesQ = $prices | Select-Object deliveryStart, @{Name="Timestamp";Expression={[System.TimeZoneInfo]::ConvertTimeFromUtc((get-date ($_.deliveryStart)), $cetZone)}}, @{Name="Price";Expression={($_.entryPerArea.BE)}} | Where-Object {($_.timestamp -ge (get-date $datetimeCET).AddHours(-1))} | Select-Object Timestamp,Price
    <##
    $pricesH = $prices | Select-Object deliveryStart, @{Name="Timestamp";Expression={[System.TimeZoneInfo]::ConvertTimeFromUtc((get-date ($_.deliveryStart)), $cetZone)}}, @{Name="Price";Expression={($_.entryPerArea.BE)}} | Select-Object Timestamp,Price
    $pricesH | Group-Object { $_.Timestamp.ToString('yyyy-MM-dd HH') } | ForEach-Object {
        $avg = [math]::Round(($_.Group.Price -replace ',', '.' | ForEach-Object {[double]$_} | Measure-Object -Average).Average,2)
        $_.Group | ForEach-Object { $_.Price = $avg }
    }
    $pricesH = $prices | Where-Object { $_.Timestamp -ge (get-date $datetimeCET).AddHours(-1) } | Select-Object Timestamp, Price
    ###>
    return $pricesQ
    
}


function Get-CloudAttenuation {
    param(
        [double]$low,  # 0..1
        [double]$mid,  # 0..1
        [double]$high  # 0..1
    )
    # Weighted cloud index: low clouds typically attenuate PV more than high cirrus.
    $wLow  = 0.6
    $wMid  = 0.3
    $wHigh = 0.1
    $idx = [math]::Min(1.0, [math]::Max(0.0, $wLow*$low + $wMid*$mid + $wHigh*$high))

    # Nonlinear attenuation: PV power ~ (1 - idx)^k ; k>1 to penalize moderate cloud more strongly.
    $k = 1.4
    $att = [math]::Pow([math]::Max(0.0, 1.0 - $idx), $k)

    # Keep nights at zero if clear_sky is zero; otherwise apply a small floor (to avoid locking to 0)
    if ($att -lt 0.02) { $att = 0.02 }
    return $att
}

function Get-PowerForecastOptimized {

    $body = @{
        date = (Get-Date $datetimeCET).ToString("dd-MM-yyyy")
        location = @{ lat = [double]$PVsettings.latitude ; lng = [double]$PVsettings.longitude }
        altitude = [int]$PVsettings.altitude
        tilt = [int]$PVsettings.tilt
        azimuth = [int]$PVsettings.orientation
        totalWattPeak = [int]$PVsettings.totalWattPeak
        wattInvertor = [int]$PVsettings.WattInvertor
        timezone = $PVsettings.timezone
    } | ConvertTo-Json -Depth 3

    # ---- 1) Get hourly cloud cover from Open-Meteo (low/mid/high) ----
    $omUrl = "https://api.open-meteo.com/v1/forecast?latitude=$($PVsettings.latitude)&longitude=$($PVsettings.longitude)" +
             "&hourly=cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,rain,showers,snowfall" +
             "&timezone=$([uri]::EscapeDataString($($PVsettings.timezone)))&forecast_days=2"

    $openmeteo = Invoke-RestMethod -Uri $omUrl -Method GET -ErrorAction Stop

    # Build a map: hour -> {low, mid, high} in fraction [0..1]
    $cloudByHour = @{}
    $times = $openmeteo.hourly.time
    for ($i=0; $i -lt $times.Count; $i++) {
        $t = [datetime]::Parse($times[$i])   # already in $tz due to timezone param
        $key = $t.ToString("yyyy-MM-dd HH:00")  # hourly key

        $cloudByHour[$key] = [pscustomobject]@{
            Low  = [double]$openmeteo.hourly.cloud_cover_low[$i]  / 100.0
            Mid  = [double]$openmeteo.hourly.cloud_cover_mid[$i]  / 100.0
            High = [double]$openmeteo.hourly.cloud_cover_high[$i] / 100.0
            All  = [double]$openmeteo.hourly.cloud_cover[$i]      / 100.0
        }
    }

    # ---- 2) Get PV forecast from api.solar-forecast.org (15-min slots) ----
    $sfUrl = "https://api.solar-forecast.org/forecast?provider=openmeteo"
    $response = Invoke-RestMethod -Uri $sfUrl -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -ErrorAction Stop

    # Convert UNIX seconds to local time and filter to now..D+2 (similar to your code)
    $nowLocal  = (Get-Date $datetimeCET).AddMinutes(-14)
    $endLocal  = (Get-Date $datetimeCET).Date.AddDays(2)

    $pv = $response |
        Select-Object *, @{
            Name="Timestamp";
            Expression={ ([System.DateTimeOffset]::FromUnixTimeSeconds($_.dt).ToLocalTime().DateTime) }
        } |
        Where-Object { $_.Timestamp -ge $nowLocal -and $_.Timestamp -lt $endLocal }



    # ---- 4) Merge by hour and compute 'P_scaled' = clear_sky * attenuation ----
    $results = foreach ($row in $pv) {
        # Round down to the nearest hour to match the Open-Meteo hourly grid
        $hourKey = (Get-Date $row.Timestamp).ToString("yyyy-MM-dd HH:00")

        $c = $null
        if ($cloudByHour.ContainsKey($hourKey)) { $c = $cloudByHour[$hourKey] }

        # If we don't have cloud data for that hour, fall back to provider 'clouds_all' if present
        $att =
            if ($c) { Get-CloudAttenuation -low $c.Low -mid $c.Mid -high $c.High }
            elseif ($row.clouds_all -ne $null) {
                # Fallback: treat 'clouds_all' as a single-layer index
                $idx = [double]$row.clouds_all / 100.0
                $idx = [math]::Min(1.0, [math]::Max(0.0, $idx))
                [math]::Pow([math]::Max(0.0, 1.0 - $idx), 1.4)
            }
            else { 1.0 }

        # clear_sky is the “unshaded” PV estimate; scale it by cloud attenuation
        $clear = [double]$row.clear_sky
        if ($clear -le 0) { $scaled = 0.0 } else { $scaled = [math]::Round($clear * $att, 3) }

        # Return both original provider PV and our scaled clear-sky; keep clouds for debugging
        [pscustomobject]@{
            Timestamp        = $row.Timestamp
            P_predicted_api  = [double]$row.P_predicted   # from api.solar-forecast.org
            clear_sky        = $clear
            P_predicted      = $scaled                    # <-- our computed value
            clouds_all_api   = $row.clouds_all
            #cloud_low_om     = if ($c) { [math]::Round($c.Low*100, 1) }  else { $null }
            #cloud_mid_om     = if ($c) { [math]::Round($c.Mid*100, 1) }  else { $null }
            #cloud_high_om    = if ($c) { [math]::Round($c.High*100, 1) } else { $null }
        }
    }

    # ---- 5) Output a minimal selection (you can export to CSV if you like) ----
    return $results | Select-Object -Property Timestamp, P_predicted
}



# Fetch Power Forecast using external api
function Get-PowerForecast {
    
    $body = @{
        date = (Get-Date $datetimeCET).ToString("dd-MM-yyyy")
        location = @{ lat = [double]$PVsettings.latitude ; lng = [double]$PVsettings.longitude }
        altitude = [int]$PVsettings.altitude
        tilt = [int]$PVsettings.tilt
        azimuth = [int]$PVsettings.orientation
        totalWattPeak = [int]$PVsettings.totalWattPeak
        wattInvertor = [int]$PVsettings.WattInvertor
        timezone = $PVsettings.timezone
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri "https://api.solar-forecast.org/forecast?provider=openmeteo" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing
    $prediction = $response | Select-Object * , @{Name="TimeStamp";Expression={([System.DateTimeOffset]::FromUnixTimeSeconds($_.dt).ToLocalTime().DateTime)}} | where-object { ($_.timestamp -ge (Get-Date $datetimeCET).AddMinutes(-14)) -and  ($_.timestamp -lt (Get-Date $datetimeCET).Date.AddDays(2))  }
    return $prediction | Select-Object -Property Timestamp, P_predicted

}

# construct the Alpha ESS authentication headers based on the specs of the API documentation


function Get-AlphaESSAuthHeaders {
    $timestamp = [math]::Floor((Get-Date).ToUniversalTime().Subtract((Get-Date "1970-01-01T00:00:00Z").ToUniversalTime()).TotalSeconds)#+3600
    $signString = "$($AlphaESSSettings.alphaEssAppId)$($AlphaESSSettings.alphaEssApiKey)$timestamp"
    $sha512 = [System.Security.Cryptography.SHA512]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($signString)
    $hashBytes = $sha512.ComputeHash($bytes)
    $sign = ([BitConverter]::ToString($hashBytes) -replace "-", "").toLower()

    return @{
        "appId"     = $AlphaESSSettings.alphaEssAppId
        "timeStamp" = $timestamp
        "sign"      = $sign
        "Content-Type" = "application/json"
    }
}


# get the current battery status (State of Charge)
function Get-BatteryStatus {
    
    $headers = Get-AlphaESSAuthHeaders
    
    # API endpoint
    $url = "https://openapi.alphaess.com/api/getLastPowerData?sysSn=$($AlphaESSSettings.alphaEssSystemId)"

    # Make the request
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers
    } catch {
       Write-Error "API call failed: $($_.Exception.Message)"
    }
    
    return $response.data.soc
}



# Send Charge Command (based on the API documentation)
function ChargeBattery($activate) {

    $headers = Get-AlphaESSAuthHeaders

    try {

        $now = Get-Date $datetimeCET
        $roundedMinutes = [math]::Floor($now.Minute / 15) * 15
        $roundedTime = Get-Date $datetimeCET -Hour $now.Hour -Minute $roundedMinutes -Second 0
        $timeStart = $roundedTime.ToString("HH:mm")
        $timeStop = $roundedTime.AddMinutes(30).ToString("HH:mm")

        $url = "https://openapi.alphaess.com/api/updateChargeConfigInfo?sysSn=$($AlphaESSSettings.alphaEssSystemId)"

        if ($activate){
            $body = @{ "sysSn" = "$($AlphaESSSettings.alphaEssSystemId)"; "gridChargePower" = $($AlphaESSControl.maxPowerFromGrid); "batHighCap" = 100; "gridCharge" = 1 ; "timeChaf1" = $timeStart; "timeChaf2" = "00:00"; "timeChae1" = $timeStop; "timeChae2" = "00:00" } | ConvertTo-Json
        }else{
            $body = @{ "sysSn" = "$($AlphaESSSettings.alphaEssSystemId)"; "gridChargePower" = $($AlphaESSControl.maxPowerFromGrid); "batHighCap" = 100; "gridCharge" = 0 ; "timeChaf1" = "00:00"; "timeChaf2" = "00:00"; "timeChae1" = "00:00"; "timeChae2" = "00:00" } | ConvertTo-Json
        }
        $out = Invoke-RestMethod -Uri $url -Headers $headers -Body $body -Method POST

    } catch {
        Write-Error "API call failed: $($_.Exception.Message)"
    }
    
    
}


# MAIN SCRIPT LOGIC

$prices = Get-EpexPrices
$soc = Get-BatteryStatus
#$PowerForecast = Get-PowerForecast
$PowerForecast = Get-PowerForecastOptimized


$joined = @()
$CummulativePowerBalance = 0
$CummulativePowerBalanceOvershoot = 0


foreach ($p in $PowerForecast) {

    $Price = ($prices | Where-Object { $_.Timestamp -eq $p.Timestamp }).Price
    $matchingPriceAVG = [math]::Round(($prices | Where-Object { $_.Timestamp -ge $p.Timestamp } | Select-Object -First $AlphaESSControl.QuartersLookahead | Measure-Object -Property Price -Average).Average,2)
    
    $sortedPrices = $prices | Where-Object { $_.Timestamp -ge $p.Timestamp } | Select-Object -ExpandProperty Price -first $AlphaESSControl.QuartersLookahead | Sort-Object Price 
    $percentileIndex = [math]::Floor($sortedPrices.Count * $AlphaESSControl.lowPriceThresholdPct)
    try{
        $matchingPricePCT = $sortedPrices[$percentileIndex]
    }catch{}
    
    $EstUsage = $usage | Where-Object { $_.hour -eq (get-date $p.Timestamp -Format "HH:00:00") }
    $EstPowerBalance = $p.P_predicted - $EstUsage.power
    
    $ChargeBattFromGrid = if ($price -and ($Price -lt $matchingPricePCT))  { $true } else { $false }

    if ((($estSoc -gt 4) -and ($estSoc -lt 100)) -or (($estSoc -ge 100) -and ($EstPowerBalance -lt 0)) -or (($estSoc -le 4) -and ($EstPowerBalance -gt 0))){
        $CummulativePowerBalance += ($EstPowerBalance/4)
    }

    $CummulativePowerBalanceOvershoot += ($EstPowerBalance/4)
    
    $estSoc = [math]::Round($soc + ($CummulativePowerBalance/100), 2)
    $estSocOvershoot = [math]::Round($soc + ($CummulativePowerBalanceOvershoot/100), 2)
    
    
    if ($estSoc -le 4){ $estSoc=4}
    if ($estSoc -ge 100){ $estSoc=100}
        
    $entry = [PSCustomObject]@{
        Timestamp       = $p.Timestamp
        P_predicted     = $p.P_predicted
        Price           = $Price # in €/MWh
        PriceAverage    = $matchingPriceAVG
        PricePercentile = $matchingPricePCT
        PriceLuminusBuy = (($Price * 0.1018 + 2.1316)/100 + 5.99/100 + 5.0329/100 + 0.2042/100)*1.06 # in €/MWh
        #PriceLuminusSell = ((1000*$Price * 0.1018 - 1.2685)/100 - 5.99/100 - 5.0329/100 - 0.2042/100)*1.06 # in €/kWh
        EstSOC          = $estSoc
        EstUsage        = $EstUsage.power
        EstPowerBalance = $EstPowerBalance
        ChargeBattFromGrid = $ChargeBattFromGrid #if (($Price -lt $matchingPricePCT) -and ($p.P_predicted -lt $EstUsage.power)) { $true } else { $false }
        ChargeBattFromGrid100 = if ($ChargeBattFromGrid){100}else{0}
        EstSOCOvershoot    = $estSocOvershoot
        EstPowerBalanceOvershoot = $CummulativePowerBalanceOvershoot
    }
    
    
    $joined +=$entry
}


$datetime = Get-Date $datetimeCET -Format "yyyy-MM-dd_HHmm"
$joined | Export-Csv -Path ".\$datetime.csv" -Delimiter ";" -NoTypeInformation
$joined | Select-Object -First 400 | Format-Table -Property *

$Current = $joined[0]
$minPredictedSOC = ($joined | Select-Object -First $AlphaESSControl.QuartersLookahead | Measure-Object -Property EstSOC -Minimum).Minimum
$maxPredictedSOC = ($joined | Select-Object -First $AlphaESSControl.QuartersLookahead | Measure-Object -Property EstSOC -Maximum).Maximum

$chargeNow = if ($Current.ChargeBattFromGrid -and ($maxPredictedSOC -lt $($AlphaESSControl.maxBatterySoC)) -and ($soc -le $($AlphaESSControl.maxBatterySoC))) {$true} else {$false}
$chargeNow100 = if ($chargeNow){100}else{0}

$ActionObj = [PSCustomObject]@{
    Timestamp       = $Current.Timestamp
    EstimatedPower  = $Current.P_predicted
    CurrentPrice    = $Current.Price
    ThresholdPrice  = $Current.PricePercentile
    LowestSOC       = $minPredictedSOC
    HighestSOC      = $maxPredictedSOC
    CurrentSOC      = $soc
    EstimatedUsage  = $Current.EstUsage
    Charge          = $chargeNow
    Charge100       = $chargeNow100
}

$ActionObj


$action = "$($Current.Timestamp);$chargeNow100;$minPredictedSOC;$SOC;$($Current.Price);$($Current.PricePercentile);$($Current.P_predicted);$($Current.EstUsage)"
$action >> ./_alphaesslog2.txt

ChargeBattery($chargeNow)

if ($HAWebhook){
    $HAjson = $actionObj | ConvertTo-Json
    Invoke-RestMethod -Uri $HAWebhook -Method Post -Body $HAjson -ContentType "application/json"
}


if ($env:AZUREPS_HOST_ENVIRONMENT) { 
    
    Set-AzStorageBlobContent -Context $ctx -Container "alphaesslogs" -File ".\$datetime.csv" -Blob ".\$datetime.csv" -Force
    Set-AzStorageBlobContent -Context $ctx -Container "alphaesslogs" -File ".\$datetime.csv" -Blob ".\_latest.csv" -Force

    $container = Get-AzStorageContainer -Name "alphaesslogs" -Context $ctx
    $appendBlob = $container.CloudBlobContainer.GetAppendBlobReference("_alphaesslog2.txt")
    
    # Prepare text
    $line = "$($Action)`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $stream = [System.IO.MemoryStream]::new($bytes)

    # Append
    $appendBlob.AppendBlock($stream, $null)
    $stream.Dispose()

}


    