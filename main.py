# -*- coding: utf-8 -*-
"""
title
    Raspberry Pi Pico 2 W Temperaturmessung (BME280) - Client
copyright
    @author:    - Ludwig, Armin
    @university:- Ernst-Abbe-Hochschule Jena
    @company:   - protronic GmbH Innovative Steuerungstechnik
    @year:      - 2025
funcionality
    Collecting data from BME280 Temperature-, Humidity- and Pressure-Sensor with Raspberry Pi Pico 2 W.
    Sending requests to HTTP-Server via WiFi-Chip getting the Server-Timestamp to actualize RTC and passing the Data to a Server in json-Format.
    
version
    Version v02.0_HTTP
history
    v01.0_TCP
    v02.0_HTTP       
add. information
    
sources
    https://randomnerdtutorials.com/raspberry-pi-pico-bme280-micropython/
"""
import machine, rp2
import utime as time
import network
import uasyncio as asyncio
#import asyncio

import urequests as ur  # für HTTP-Version
#import socket, json     # für TCP Version

#import BME280
import bme280_self as BME280
from config import secrets

## Sensor Konfiguration
sens_id=secrets['sensor_id']
## Wi-Fi Konfiguration
SSID = secrets['ssid']
try:
    PW = secrets['pw']
except KeyError:
    PW = ''
network.country('DE')
## Server Konfiguration
SERVER_URL = secrets['server_url']
HOST = secrets['server_ip']
PORT = secrets['server_port']

led = machine.Pin("LED", machine.Pin.OUT)
interval=secrets['interval'] #Data-Aquisition-Timer Interval [ms]
rtc=machine.RTC()

## Initialize I2C communication
#i2c = machine.I2C(id=0, scl=machine.Pin(5), sda=machine.Pin(4), freq=10000)
i2c = machine.I2C(id=secrets['i2c_bus'], scl=machine.Pin(secrets['scl_pin']), sda=machine.Pin(secrets['sda_pin']), freq=10000)
## Initialize BME280 sensor
bme = BME280.BME280(i2c=i2c, osmode=3)
# osmode: Temperature oversampling (3 => x4)
# BME280 default address (I2C0): BME280_I2CADDR = 0x76

## Enable the WDT with a timeout of 6s (1s is the minimum)
wdt = machine.WDT(timeout=6000)

## Use dummy WDT for testing without hardware watchdog
# class _DummyWDT:
#     def feed(self): pass
# wdt = _DummyWDT()

def read_data(data_timer):
    try:
        ## Read sensor data
        tempC = bme.temperature
        hum = bme.humidity
        pres = bme.pressure
    except Exception as e:
        print(rtc.datetime(), "Error while acquiring data: ", e)###############
    wdt.feed() # prevent wdt to restart the system
    send_data(tempC, hum, pres)
    
def send_data(tempC, hum, pres):
    global rtc_isupdated
    if rtc_isupdated:
        tt = rtc.datetime()
        time = f'{tt[0]}-{tt[1]:02d}-{tt[2]:02d} {tt[4]:02d}:{tt[5]:02d}:{tt[6]:02d}' # yyyy-MM-dd HH:mm:ss[.nnn]
    else:
        time = 'XXXX-XX-XX XX:XX:XX'
    wdt.feed() # prevent wdt to restart the system
    ## Create json-object with sensor data
    data_package = {"Messzeit": time, 
                    "Luftfeuchte": hum, 
                    "Temperatur": tempC, 
                    "Druck": pres, 
                    "StandortID": sens_id,}
    #print(f"{time} - Temperatur: {tempC} °C")
    try:
        s = ur.request ("POST", SERVER_URL, json=data_package)
        print(f'{time} - Code: {s.status_code}')
    except Exception as e:
        print(rtc.datetime(), "Error while sending data: ", e)#################
    finally:
        s.close()
    wdt.feed() # prevent wdt to restart the system

def update_rtc(rtc_update_timer):
    global rtc_isupdated
    rtc_isupdated = receive_time()

def receive_time():
    try:
        ## Ask for actual server time to keep rtc up to date
        response = ur.get(SERVER_URL)
        timestamp = response.headers.get('Date') # GMT timestamp
    except Exception as e:
        print(rtc.datetime(), "Error while getting Server-Time: ", e)##########
        timestamp = None
    finally:
        response.close()
    wdt.feed() # prevent wdt to restart the system
    if timestamp:
        try:
            month_str = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            month_int = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"]
            week_str = ["Mon,", "Tue,", "Wed,", "Thu,", "Fri,", "Sat,", "Sun,"]
            week_int = ["0", "1", "2", "3", "4", "5", "6"]
            for i in range(len(month_str)):
                timestamp = timestamp.replace(month_str[i], month_int[i])
                wdt.feed() # prevent wdt to restart the system
            for j in range(len(week_str)):
                timestamp = timestamp.replace(week_str[j], week_int[j])
                wdt.feed() # prevent wdt to restart the system
            week, day, month, year, time = timestamp.split()[:5]
            hour, minute, second = time.split(":")
            rtc.datetime(tuple(map(int, (year, month, day, week, hour, minute, second, 0))))
            wdt.feed() # prevent wdt to restart the system
            return True
        except Exception as e:
            print(rtc.datetime(), "Error while converting Time-Format: ", e)###
            return False
    else:
        return False
        
def blink_led(num_blinks):
    if num_blinks>0:
        for i in range(num_blinks):
            led.on()
            time.sleep(.15)
            led.off()
            time.sleep(.35)
    elif num_blinks<0:
        for i in range(abs(num_blinks)):
            led.on()
            time.sleep_ms(50)
            led.off()
            time.sleep(.12)
            led.on()
            time.sleep_ms(50)
            led.off()
            time.sleep(.28)

def wlanConnect():
    wlan = network.WLAN(network.STA_IF) #STA_IF -> Station, device behaves like Wi-Fi client connecting to existing network  #AP_IF -> Access Point, device acts like Wi-Fi hotspot, allowing to connect to it
    if not wlan.isconnected():
        wlan.config(pm = 0xa11140)  #to disable power saving mode
        wlan.active(True)

        # mac = wlan.config('mac')
        # print("MAC:", ':'.join('{:02X}'.format(b) for b in mac))
        # nets = wlan.scan()
        # for n in nets:
        #     print(n[0].decode(), '| RSSI:', n[3], '| Security:', n[4])

        if PW == '':
            wlan.connect(SSID)
        else:
            wlan.connect(SSID, PW)
        time.sleep(1)
        for i in range(40):
            if wlan.status() < 0 or wlan.status() >= 3:
                break
            wdt.feed() # prevent wdt to restart the system
            time.sleep(.25)
    if wlan.isconnected():
        netConfig = wlan.ifconfig()
        return netConfig[0], wlan.isconnected(), wlan.status()
    else:
        return '', wlan.isconnected(), wlan.status()

# Mapping CYW43 error codes to their descriptions
CYW43_ERROR_CODES = {
    0:  "CYW43_LINK_DOWN",# - No WiFi connection",
    1:  "CYW43_LINK_JOIN",# - Connection attempt in progress",
    2:  "CYW43_LINK_NOIP",# - Connected but no IP configuration",
    3:  "CYW43_LINK_UP",# - Connection successful",
   -1: "CYW43_LINK_FAIL",# - Connection aborted",
   -2: "CYW43_LINK_NONET",# - WiFi network not found",
   -3: "CYW43_LINK_BADAUTH",# - Authentication failed (wrong password)",
   }

async def pulse_led():
    global running
    while running:
        led.on()
        await asyncio.sleep(.3)
        led.off()
        await asyncio.sleep(1.7)
''' Error JSON:
    error_transmission = {"time": rtc.datetime(),
                          "place": "read_data"/"send_data"/"receive_time"/"wlanConnect",
                          "descr.": "Error while acquiring data: "/"Error while sending data: "...,
                          "e-Code": e}
'''


wdt.feed() # prevent wdt to restart the system
led.on()
ipv4, wlan_isconnected, wlan_status = wlanConnect()
led.off()
if wlan_isconnected:
    print(rtc.datetime(), f'Connected to WLAN: {ipv4}')########################
    time.sleep(.5)
    blink_led(wlan_status)
    
    ## Ask for actual server time to keep rtc up to date
    rtc_isupdated = receive_time()

    if secrets['per_dataacq']:
        data_timer = machine.Timer()
        data_timer.init(period=interval, mode=machine.Timer.PERIODIC, callback=read_data)
    else:
        data_timer = machine.Timer()
        data_timer.init(period=interval, mode=machine.Timer.ONE_SHOT, callback=read_data)
    rtc_update_timer = machine.Timer()
    rtc_update_timer.init(period=2419200, mode=machine.Timer.PERIODIC, callback=update_rtc) # 28 days

    async def main_loop():
        global running
        while True:
            if rp2.bootsel_button():
                rtc_update_timer.deinit()
                data_timer.deinit()
                running = False
                break
            else:
                pass
                # Put the microcontroller in idle mode to save power while waiting
                #machine.idle()
                #machine.sleep()
            await asyncio.sleep(.001)

    async def main():
        task_pulse = asyncio.create_task(pulse_led())
        task_main_loop = asyncio.create_task(main_loop())
        await asyncio.gather(task_pulse, task_main_loop)

    running = True
    asyncio.run(main())
    
else:
    print(rtc.datetime(), 'Failed WLAN-Connection:', CYW43_ERROR_CODES.get(wlan_status, "Unknown error code."))
    time.sleep(.5)
    blink_led(wlan_status)
    # Programmabbruch