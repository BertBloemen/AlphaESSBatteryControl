# CONFIGURATION

$AlphaESSControlConfig = [XML](Get-Content .\AlphaESSControlConfig.Xml)

$alphaEssAppId = $AlphaESSControlConfig.AlphaESSControlConfig.alphaEssSettings.alphaEssAppId
$alphaEssApiKey = $AlphaESSControlConfig.AlphaESSControlConfig.alphaEssSettings.alphaEssApiKey
$alphaEssSystemId = $AlphaESSControlConfig.AlphaESSControlConfig.alphaEssSettings.alphaEssSystemId

$maxPowerFromGrid = [int]$AlphaESSControlConfig.AlphaESSControlConfig.controlSettings.maxPowerFromGrid
$minBatterySoC = [int]$AlphaESSControlConfig.AlphaESSControlConfig.controlSettings.minBatterySoC
$maxBatterySoC = [int]$AlphaESSControlConfig.AlphaESSControlConfig.controlSettings.maxBatterySoC
$lowPriceThresholdPct = [double]$AlphaESSControlConfig.AlphaESSControlConfig.controlSettings.lowPriceThresholdPct
$highPriceThresholdPct = [double]$AlphaESSControlConfig.AlphaESSControlConfig.controlSettings.highPriceThresholdPct

# FUNCTIONS


# 1. Fetch EPEX Spot Prices (example placeholder)
function Get-EpexPrices {
    
    
    $today = get-date -Format "yyyy-MM-dd"
    $tomorrow = get-date (get-date).AddDays(1) -Format "yyyy-MM-dd"

    $prices = ((Invoke-WebRequest -UseBasicParsing -Uri "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?market=DayAhead&deliveryArea=BE&currency=EUR&date=$today").content | ConvertFrom-Json).multiAreaEntries
    $prices += ((Invoke-WebRequest -UseBasicParsing -Uri "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?market=DayAhead&deliveryArea=BE&currency=EUR&date=$tomorrow").content | ConvertFrom-Json).multiAreaEntries

    
    $prices = $prices | select deliveryStart, @{Name="Timestamp";Expression={get-date ($_.deliveryStart)}}, @{Name="Price";Expression={($_.entryPerArea.BE/1000)}} | Where-Object {($_.timestamp -ge (get-date).AddHours(-1))} | Select-Object Timestamp,Price

    
    return $prices
    
}

# 2. Fetch Power Forecast
function Get-PowerForecast {

    $body = @{
        date = (Get-Date).ToString("dd-MM-yyyy")
        location = @{ lat = 51.22; lng = 4.40 }
        altitude = 10
        tilt = 35
        azimuth = 180
        totalWattPeak = 6125
        wattInvertor = 5000
        timezone = "Europe/Brussels"
    } | ConvertTo-Json -Depth 3

    #$openmeteo = Invoke-RestMethod -Uri "https://api.open-meteo.com/v1/forecast?latitude=51.2205&longitude=4.4003&hourly=cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,rain,showers,snowfall&timezone=Europe%2FBerlin&forecast_days=1"

    $response = Invoke-RestMethod -Uri "https://api.solar-forecast.org/forecast?provider=openmeteo" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing
    $prediction = $response | select * , @{Name="TimeStamp";Expression={([System.DateTimeOffset]::FromUnixTimeSeconds($_.dt).ToLocalTime().DateTime)}} | where-object { ($_.timestamp -ge (Get-Date).AddMinutes(-14)) -and  ($_.timestamp -lt (Get-Date).Date.AddDays(2))  }
    return $prediction | select -Property Timestamp, P_predicted, clear_sky, clouds_all

}

function Get-AlphaESSAuthHeaders {
    $timestamp = [math]::Floor((Get-Date).ToUniversalTime().Subtract((Get-Date "1970-01-01T00:00:00Z")).TotalSeconds)+3600
    $signString = "$alphaEssAppId$alphaEssApiKey$timestamp"
    $sha512 = [System.Security.Cryptography.SHA512]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($signString)
    $hashBytes = $sha512.ComputeHash($bytes)
    $sign = ([BitConverter]::ToString($hashBytes) -replace "-", "").toLower()

    return @{
        "appId"     = $alphaEssAppId
        "timeStamp" = $timestamp
        "sign"      = $sign
    }
}


# 3. Fetch Battery Status
function Get-BatteryStatus {
    
    $headers = Get-AlphaESSAuthHeaders
    
    # API endpoint
    $url = "https://openapi.alphaess.com/api/getLastPowerData?sysSn=$alphaEssSystemId"

    # Make the request
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers
    } catch {
        Write-Error "API call failed: $($_.Exception.Message)"
    }
    
    return $response.data.soc
}



# 5. Send Charge Command
function ChargeBattery($activate) {

    $headers = Get-AlphaESSAuthHeaders

    try {

        $now = Get-Date
        $roundedMinutes = [math]::Floor($now.Minute / 15) * 15
        $roundedTime = Get-Date -Hour $now.Hour -Minute $roundedMinutes -Second 0
        $timeStart = $roundedTime.ToString("HH:mm")
        $timeStop = $roundedTime.AddMinutes(15).ToString("HH:mm")

        $url = "https://openapi.alphaess.com/api/updateChargeConfigInfo?sysSn=$alphaEssSystemId"

        if ($activate){
            $body = @{ "sysSn" = "$alphaEssSystemId"; "gridChargePower" = $maxPowerFromGrid; "batHighCap" = $maxBatterySoC; "gridCharge" = 1 ; "timeChaf1" = $timeStart; "timeChaf2" = "00:00"; "timeChae1" = $timeStop; "timeChae2" = "00:00" } | ConvertTo-Json
        }else{
            $body = @{ "sysSn" = "$alphaEssSystemId"; "gridChargePower" = $maxPowerFromGrid; "batHighCap" = $maxBatterySoC; "gridCharge" = 0 ; "timeChaf1" = "00:00"; "timeChaf2" = "00:00"; "timeChae1" = "00:00"; "timeChae2" = "00:00" } | ConvertTo-Json
        }
        $out = Invoke-RestMethod -Uri $url -Headers $headers -Body $body -Method POST

    } catch {
        Write-Error "API call failed: $($_.Exception.Message)"
    }
    
    
}



$prices = Get-EpexPrices
$soc = Get-BatteryStatus
$PowerForecast = Get-PowerForecast

#$lowPriceThreshold = ($prices | Measure-Object -Property Price -Average).Average

$sortedPrices = $prices | Sort-Object Price | Select-Object -ExpandProperty Price
$percentileIndex = [math]::Floor($sortedPrices.Count * $lowPriceThresholdPct)
$lowPriceThreshold = $sortedPrices[$percentileIndex]


$avgPrice = ($prices | Measure-Object -Property Price -Average).Average
$minPrice = ($prices | Measure-Object -Property Price -Minimum).Minimum
$PowerPrediction = ($PowerForecast | where-object {$_.timestamp -lt (get-date).AddHours(24)} | Measure-Object -Property P_predicted -Sum).Sum /4
$PowerMax = ($PowerForecast | where-object {$_.timestamp -lt (get-date).AddHours(24)} | Measure-Object -Property clear_sky -Sum).Sum /4


$usage = Import-Csv ".\usage.txt" -Delimiter ","
$minSoc = 15

$joined = @()
$CummulativePowerBalance = 0


foreach ($p in $PowerForecast) {

    $matchingPrice = $prices | Where-Object { $_.Timestamp -eq $p.Timestamp }
    $EstUsage = $usage | Where-Object { $_.hour -eq (get-date $p.Timestamp -Format "HH:00:00") }
    $EstPowerBalance = $p.P_predicted - $EstUsage.power
    $Price=$matchingPrice.Price

    if (($estSoc -gt 4) -and ($estSoc -lt 100)){
        $CummulativePowerBalance += ($EstPowerBalance/4)
    }else{
        if ((($estSoc -ge 100) -and ($EstPowerBalance -lt 0)) -or (($estSoc -le 4) -and ($EstPowerBalance -gt 0))){
            $CummulativePowerBalance += ($EstPowerBalance/4)
        }
    }
        
    $estSoc = [math]::Round($soc + ($CummulativePowerBalance/100), 2)
    if ($estSoc -le 4){ $estSoc=4}
    if ($estSoc -ge 100){ $estSoc=100}
        
    $entry = [PSCustomObject]@{
        Timestamp   = $p.Timestamp
        P_predicted = $p.P_predicted
        Price       = $Price # in €/kWh
        PriceLuminusBuy = ((1000*$Price * 0.1018 + 2.1316)/100 + 5.99/100 + 5.0329/100 + 0.2042/100)*1.06 # in €/kWh
        #PriceLuminusSell = ((1000*$Price * 0.1018 - 1.2685)/100 - 5.99/100 - 5.0329/100 - 0.2042/100)*1.06 # in €/kWh
        EstSOC      = $estSoc
        EstUsage    = $EstUsage.power
        EstPowerBalance = $EstPowerBalance
        ChargeBattFromGrid  = if (($Price -lt $lowPriceThreshold) -and ($p.P_predicted -lt $EstUsage.power)) { $true } else { $false }
    }
        
    $joined +=$entry
}


$datetime = Get-Date -Format "dd-MM-yyyy_HHmm"
$joined | Select-Object -First 400 | ft -Property *
$joined | Export-Csv -Path ".\logs\$datetime.csv" -Delimiter ";" -NoTypeInformation

$minSOC = ($joined | Select-Object -First 50 | measure -Property EstSOC -Minimum).Minimum

if ($joined[0].ChargeBattFromGrid -and ($minSOC -lt 10)){
    "$datetime - Start opladen, minSoc=$minSOC, price=$($joined[0].Price), price_threshold=$lowPriceThreshold"
    "$datetime - Start opladen, minSoc=$minSOC, price=$($joined[0].Price), price_threshold=$lowPriceThreshold" >> .\logs\_alphaesslog.txt
    ChargeBattery($true)
}else{
    "$datetime - Stop opladen, minSoc=$minSOC, price=$($joined[0].Price), price_threshold=$lowPriceThreshold"
    "$datetime - Stop opladen, minSoc=$minSOC, price=$($joined[0].Price), price_threshold=$lowPriceThreshold" >> .\logs\_alphaesslog.txt
    ChargeBattery($false)
}
    

    
Write-Host "Current SOC = $soc"
Write-Host "Current Price = $($joined[0].Price)"
Write-Host "Avg Price = $avgPrice"
Write-Host "Min Price = $minPrice"
Write-Host "Low Price threshold = $lowPriceThreshold"
Write-Host "Total Power Prediction = $PowerPrediction"
Write-Host "Total Power Max = $PowerMax"
     
