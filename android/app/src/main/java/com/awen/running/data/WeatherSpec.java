package com.awen.running.data;

import java.util.ArrayList;

/**
 * 天气数据规格（对齐 Gadgetbridge WeatherSpec 的字段子集）
 * 温度统一使用开尔文（Kelvin），与上游保持一致；发送给手表时再转换为摄氏度。
 */
public class WeatherSpec {

    public int timestamp; // 观测时间，Unix 秒
    public int currentTemp; // 当前温度，Kelvin
    public int currentConditionCode = 3200; // OpenWeatherMap 天气代码
    public int currentHumidity; // 湿度 %
    public int todayMaxTemp; // 今日最高温，Kelvin
    public int todayMinTemp; // 今日最低温，Kelvin
    public float windSpeed; // km/h
    public int windDirection; // 角度 0-360
    public String location; // 城市名
    public float uvIndex = -1; // 紫外线指数
    public int sunRise; // Unix 秒
    public int sunSet; // Unix 秒
    public int moonRise; // Unix 秒
    public int moonSet; // Unix 秒
    public int moonPhase; // 角度 0-360
    public AirQuality airQuality;
    public ArrayList<Daily> forecasts = new ArrayList<>();
    public ArrayList<Hourly> hourly = new ArrayList<>();

    /**
     * 将风速 km/h 转换为蒲福风级
     */
    public int windSpeedAsBeaufort() {
        return toBeaufort(this.windSpeed);
    }

    public static int toBeaufort(float kmPerHour) {
        if (kmPerHour < 1) return 0;
        if (kmPerHour < 6) return 1;
        if (kmPerHour < 12) return 2;
        if (kmPerHour < 20) return 3;
        if (kmPerHour < 29) return 4;
        if (kmPerHour < 39) return 5;
        if (kmPerHour < 50) return 6;
        if (kmPerHour < 62) return 7;
        if (kmPerHour < 75) return 8;
        if (kmPerHour < 89) return 9;
        if (kmPerHour < 103) return 10;
        if (kmPerHour < 118) return 11;
        return 12;
    }

    public static class AirQuality {
        public int aqi = -1;
        public float pm25 = -1;
    }

    public static class Daily {
        public int timestamp; // Unix 秒
        public int maxTemp; // Kelvin
        public int minTemp; // Kelvin
        public int conditionCode; // OWM code
        public int humidity;
        public float windSpeed; // km/h
        public int windDirection;
        public int sunRise;
        public int sunSet;
        public int moonRise;
        public int moonSet;
        public int moonPhase;

        public int windSpeedAsBeaufort() {
            return WeatherSpec.toBeaufort(this.windSpeed);
        }
    }

    public static class Hourly {
        public int timestamp; // Unix 秒
        public int temp; // Kelvin
        public int conditionCode; // OWM code
        public int humidity;
        public float windSpeed; // km/h
        public int windDirection;

        public int windSpeedAsBeaufort() {
            return WeatherSpec.toBeaufort(this.windSpeed);
        }
    }
}
