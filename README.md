# AlphaESSBatteryControl
Dynamic steering script for the Alpha ESS Battery.
Create the AlphaESSControlConfig.xml file in the same directory with the following structure:



```xml
<?xml version="1.0" encoding="UTF-8"?>
<AlphaESSControlConfig>
    <alphaEssISettings>
        <alphaEssInverterModel>AlphaESS X3</alphaEssInverterModel>
        <alphaEssAppId>alphaxxxxxxxxxxxxxxxxxxx</alphaEssAppId>
        <alphaEssApiKey>xxxxxxxxxxxxxxxxxxxxxxx</alphaEssApiKey>
        <alphaEssSystemId>ALDxxxxxxxxxxxxxxxxxx</alphaEssSystemId>
    </alphaEssISettings>
    <controlSettings>
        <minBatterySoC>15</minBatterySoC>
        <maxBatterySoC>95</maxBatterySoC>
        <maxPowerFromGrid>3000</maxPowerFromGrid>
        <lowPriceThresholdPct>0.25</lowPriceThresholdPct>
        <highPriceThresholdPct>0.75</highPriceThresholdPct>
    </controlSettings>
</AlphaESSControlConfig>
</AlphaESSControlConfig>
```

Usage.txt is a csv with estimated power consumption per hour.
