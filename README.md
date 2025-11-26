# AlphaESSBatteryControl
Dynamic steering script for the Alpha ESS Battery.
Create the AlphaESSControlConfig.xml file in the same directory with the following structure:



```xml
<?xml version="1.0" encoding="UTF-8"?>
<AlphaESSControlConfig>
    <alphaEssSettings>
        <alphaEssInverterModel>AlphaESS X3</alphaEssInverterModel>
        <alphaEssAppId>alphaxxxxxxxxxxxxxxxxxxx</alphaEssAppId>
        <alphaEssApiKey>xxxxxxxxxxxxxxxxxxxxxxx</alphaEssApiKey>
        <alphaEssSystemId>ALDxxxxxxxxxxxxxxxxxx</alphaEssSystemId>
    </alphaEssSettings>
    <controlSettings>
        <minBatterySoC>15</minBatterySoC>
        <maxBatterySoC>95</maxBatterySoC>
        <maxPowerFromGrid>3000</maxPowerFromGrid>
        <lowPriceThresholdPct>0.25</lowPriceThresholdPct>
        <highPriceThresholdPct>0.75</highPriceThresholdPct>
    </controlSettings>
    <PVSettings>
        <latitude>51.22</latitude>
        <longitude>4.4</longitude>
        <altitude>10</altitude>
        <tilt>0.25</tilt>
        <orientation>180</orientation>
        <totalWattPeak>6125</totalWattPeak>
        <WattInvertor>5000</WattInvertor>
        <timezone>Europe/Brussels</timezone>
    </PVSettings>
</AlphaESSControlConfig>
</AlphaESSControlConfig>
```

Usage.txt is a csv with estimated power consumption per hour.
