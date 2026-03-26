

# load the config files
[xml]$AlphaESSControlConfig = Get-Content -Path "AlphaESSControlConfig.xml"

$PVsettings = $AlphaESSControlConfig.AlphaESSControlConfig.PVSettings

$utcNow = (Get-Date).ToUniversalTime()
$cetZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Central European Standard Time")
$datetimeCET = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $cetZone)



    $body = @{
        date = (Get-Date $datetimeCET).ToString("dd-MM-yyyy")
        location = @{ lat = [double]$PVsettings.latitude ; lng = [double]$PVsettings.longitude }
        altitude = [int]$PVsettings.altitude
        tilt = [int]$PVsettings.tilt
        azimuth = [int]$PVsettings.orientation
        totalWattPeak = [int]$PVsettings.totalWattPeak
        wattInvertor = [int]$PVsettings.WattInvertor
        #timezone = $PVsettings.timezone
    } | convertto-json -Depth 5

$body
    
    # ---- 2) Get PV forecast from api.solar-forecast.org (15-min slots) ----
    #$sfUrl = "https://api.solar-forecast.org/forecast"
    $sfUrl = "https://pvforecast-hncvhda0cad7cra8.westeurope-01.azurewebsites.net/forecast"
    $response = Invoke-RestMethod -Uri $sfUrl -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -ErrorAction Stop


    $response