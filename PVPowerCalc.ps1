function Get-PVForecast {
    param(
        [Parameter(Mandatory=$true)]
        [datetime]$datetimeCET,

        [Parameter(Mandatory=$true)]
        $PVsettings
    )

    # -------------------------------------------
    # IANA Timezone → UTC offset (DST-aware)
    # -------------------------------------------
    function Get-TimezoneOffsetHours {
        param(
            [datetime]$dt,
            [string]$ianaTZ
        )

        try {
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($ianaTZ)
        }
        catch {
            switch ($ianaTZ) {
                "Europe/Brussels" { 
                    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Romance Standard Time") 
                }
                Default { throw "Unsupported timezone: $ianaTZ" }
            }
        }

        return $tz.GetUtcOffset($dt).TotalHours
    }

    function Deg2Rad { param([double]$deg) return ($deg * [Math]::PI / 180.0) }
    function Rad2Deg { param([double]$rad) return ($rad * 180.0 / [Math]::PI) }

    # -------------------------------------------
    # Solar model (Spencer/NOAA)
    # -------------------------------------------
    function Get-SunPosition {
        param(
            [datetime]$dt,
            [double]$lat,
            [double]$lng,
            [double]$utcOffset
        )

        $hour = $dt.Hour + ($dt.Minute / 60.0)
        $N = $dt.DayOfYear
        $gamma = 2.0 * [Math]::PI * ($N - 1) / 365.0

        # Declination
        $declRad =
            0.006918 -
            0.399912 * [Math]::Cos($gamma) +
            0.070257 * [Math]::Sin($gamma) -
            0.006758 * [Math]::Cos(2 * $gamma) +
            0.000907 * [Math]::Sin(2 * $gamma) -
            0.002697 * [Math]::Cos(3 * $gamma) +
            0.001480 * [Math]::Sin(3 * $gamma)

        # Equation of time
        $B = Deg2Rad((360.0 / 365.0) * ($N - 81))
        $EoT = 9.87 * [Math]::Sin(2 * $B) - 7.53 * [Math]::Cos($B) - 1.5 * [Math]::Sin($B)

        # Solar time (DST‑aware)
        $solarTime = $hour + (($EoT + 4.0 * $lng - 60.0 * $utcOffset) / 60.0)

        # Hour angle
        $H = Deg2Rad(15.0 * ($solarTime - 12.0))
        $latRad = Deg2Rad($lat)

        # Altitude
        $alt = [Math]::Asin(
            [Math]::Sin($latRad) * [Math]::Sin($declRad) +
            [Math]::Cos($latRad) * [Math]::Cos($declRad) * [Math]::Cos($H)
        )

        if ($alt -lt 0) {
            return [PSCustomObject]@{ AltitudeRad = -1; AzimuthRad = 0 }
        }

        # Azimuth
        $cosAz = (
            [Math]::Sin($declRad) - 
            [Math]::Sin($latRad) * [Math]::Sin($alt)
        ) / ([Math]::Cos($latRad) * [Math]::Cos($alt))

        if ($cosAz -gt 1) { $cosAz = 1 }
        if ($cosAz -lt -1) { $cosAz = -1 }

        $az = [Math]::Acos($cosAz)
        if ($H -gt 0) { $az = 2 * [Math]::PI - $az }

        return [PSCustomObject]@{
            AltitudeRad = $alt
            AzimuthRad  = $az
        }
    }

    # -------------------------------------------
    # Medium‑tuned PV Model
    # -------------------------------------------
    function Get-PVPower {
        param(
            [double]$altRad,
            [double]$azRad,
            [double]$tiltDeg,
            [double]$panelAzDeg,
            [int]$Wp,
            [int]$invLimit
        )

        if ($altRad -lt 0) { return 0 }

        $tiltRad = Deg2Rad($tiltDeg)
        $panelAzRad = Deg2Rad($panelAzDeg)

        # AOI cosine
        $cosAOI =
            [Math]::Cos($tiltRad) * [Math]::Sin($altRad) +
            [Math]::Sin($tiltRad) * [Math]::Cos($altRad) *
            [Math]::Cos($azRad - $panelAzRad)

        if ($cosAOI -lt 0) { $cosAOI = 0 }

        # Medium‑tuned AOI: soften losses
        $cosAOI_eff = 0.8 + 0.2 * $cosAOI  # preserves 80% even at low angles

        # Enhanced clear-sky irradiance
        $G0 = 1080.0 * [Math]::Sin($altRad)
        if ($G0 -lt 0) { $G0 = 0 }

        # Direct irradiance on panel
        $Gdir = $G0 * $cosAOI_eff

        # Diffuse sky irradiance (medium realism)
        $Gdiff = 120.0 + 80.0 * [Math]::Sin($altRad)
        if ($Gdiff -lt 0) { $Gdiff = 0 }

        # Rough tilt factor for diffuse
        $Gdiff_tilt = $Gdiff * 0.5

        # Total irradiance
        $G = $Gdir + $Gdiff_tilt

        # Convert to power
        $power = $Wp * ($G / 1000.0)

        # Panel performance boost (modern mono ~ +8%)
        $power *= 1.08

        # Inverter clipping
        if ($power -gt $invLimit) { $power = $invLimit }

        return [Math]::Round($power, 1)
    }

    # -------------------------------------------
    # Main loop
    # -------------------------------------------
    $results = @()
    $start = $datetimeCET

    for ($i = 0; $i -lt 48 * 4; $i++) {

        $t = $start.AddMinutes(15 * $i)
        $utcOffset = Get-TimezoneOffsetHours -dt $t -ianaTZ $PVsettings.timezone

        $sun = Get-SunPosition -dt $t -lat $PVsettings.latitude -lng $PVsettings.longitude -utcOffset $utcOffset

        $pv = Get-PVPower `
            -altRad $sun.AltitudeRad `
            -azRad $sun.AzimuthRad `
            -tiltDeg $PVsettings.tilt `
            -panelAzDeg $PVsettings.orientation `
            -Wp $PVsettings.totalWattPeak `
            -invLimit $PVsettings.wattInvertor

        $results += [PSCustomObject]@{
            timestamp = $t.ToString("yyyy-MM-dd HH:mm")
            expectedPowerWatt = $pv
        }
    }

    return $results
}