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

import urequests as ur  # für HTTP-Version
import ujson as json

#import BME280
import bme280_self as BME280
from config import secrets
from thingsboard_sdk.tb_device_mqtt import TBDeviceMqttClient
from micro_dotenv import load_dotenv, get_env

## Load environment variables from .env file
load_dotenv()

## Sensor Konfiguration
sens_id=get_env('DEPLOY_LOCATION')
## Server Konfiguration
SERVER_URL = secrets['server_url']
PORT = secrets['server_port']

led = machine.Pin("LED", machine.Pin.OUT)
interval=secrets['interval'] #Data-Aquisition-Timer Interval [ms]
rtc=machine.RTC()

## Initialize I2C communication
# i2c = machine.I2C(id=0, scl=machine.Pin(5), sda=machine.Pin(4), freq=10000)
i2c = machine.I2C(int(secrets['i2c_bus']), scl=machine.Pin(secrets['scl_pin']), sda=machine.Pin(secrets['sda_pin']), freq=int(10000))
## Initialize BME280 sensor
bme = BME280.BME280(i2c=i2c, osmode=3)
# osmode: Temperature oversampling (3 => x4)
# BME280 default address (I2C0): BME280_I2CADDR = 0x76

def rpc_handler(request_id, request_body):
    if tb_client is None:
        return
    method = request_body.get('method')
    params = request_body.get('params', {})
    if isinstance(params, str):
        try:
            params = json.loads(params)
        except (ValueError, Exception):
            params = {}
    if method == 'uploadFile':
        filename = params.get('filename', '')
        content  = params.get('content', '')
        if not filename:
            tb_client.send_rpc_reply(request_id, {'success': False, 'error': 'No filename'})
            return
        try:
            with open(filename, 'w') as f:
                f.write(content)
            print(rtc.datetime(), f'RPC uploadFile: {filename} written ({len(content)} bytes)')
            tb_client.send_rpc_reply(request_id, {'success': True, 'filename': filename})
        except Exception as e:
            tb_client.send_rpc_reply(request_id, {'success': False, 'error': str(e)})
    elif method == 'reboot':
        tb_client.send_rpc_reply(request_id, {'success': True})
        time.sleep_ms(500)
        machine.reset()


## Connect to ThingsBoard via MQTT
tb_client = TBDeviceMqttClient(get_env("MQTT_BROKER"), int(get_env("MQTT_PORT")), get_env("MQTT_ACCESS_TOKEN"))
tb_client.set_server_side_rpc_request_handler(rpc_handler)
try:
    tb_client.connect()
    print('ThingsBoard MQTT connected')
    time.sleep_ms(500)  # Allow connection to establish
    tb_client.send_attributes({
        'location':    get_env('DEPLOY_LOCATION'),
        'commit_hash': get_env('DEPLOY_COMMIT_HASH'),
        'git_url':     get_env('DEPLOY_GIT_URL'),
        'wifi_ssid':   get_env('WIFI_SSID', ''),
        'version':     get_env('SOFTWARE_VERSION', 'unknown'),
        'test_client': False,
    })
except Exception as e:
    print('ThingsBoard MQTT connect failed:', e)
    tb_client = None  # Set to None if connection fails


if secrets['use_wdt']:
    ## Enable the WDT with a timeout of 8,3s (1s is the minimum)
    wdt = machine.WDT(timeout=8388)
else:
    ## Use dummy WDT for testing without hardware watchdog
    class _DummyWDT:
        def feed(self): pass
    wdt = _DummyWDT()

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

    if tb_client is not None:
        try:
            del data_package['Messzeit']
            del data_package['StandortID']
            tb_client.send_telemetry(data_package)
        except Exception as e:
            print(rtc.datetime(), "Error while sending data to ThingsBoard: ", e)#################

    wdt.feed() # prevent wdt to restart the system

def update_rtc(rtc_update_timer):
    global rtc_isupdated
    rtc_isupdated = receive_time()

def receive_time():
    if tb_client is not None:
        return _receive_time_mqtt()
    return _receive_time_http()

def _receive_time_mqtt():
    ## Requests current server time from ThingsBoard via client-side RPC.
    ## Requires a ThingsBoard rule chain that handles 'getServerTime'
    ## and responds with {"ts": <unix_ms>}.
    if tb_client is None:
        print(rtc.datetime(), 'MQTT client not connected, falling back to HTTP')
        return _receive_time_http()
    
    _result = {}

    def _on_time_response(request_id, response, exception):
        if exception is None and isinstance(response, dict):
            ts_ms = response.get('ts') or response.get('serverTime')
            if ts_ms:
                _result['ts'] = int(ts_ms)

    try:
        tb_client.send_rpc_call('getServerTime', {}, _on_time_response)
        deadline = time.ticks_add(time.ticks_ms(), 5000)
        while 'ts' not in _result and time.ticks_diff(deadline, time.ticks_ms()) > 0:
            tb_client.check_for_msg()
            time.sleep_ms(100)
            wdt.feed()
        if 'ts' not in _result:
            print(rtc.datetime(), 'Error while getting Server-Time: no response from ThingsBoard')
            return False
        ## gmtime: (year, month, mday, hour, minute, second, weekday, yearday)
        tt = time.gmtime(_result['ts'] // 1000)
        rtc.datetime((tt[0], tt[1], tt[2], tt[6], tt[3], tt[4], tt[5], 0))
        wdt.feed()
        return True
    except Exception as e:
        print(rtc.datetime(), 'Error while getting Server-Time (MQTT): ', e)###
        print(rtc.datetime(), 'Falling back to HTTP time sync')
        return _receive_time_http()

def _receive_time_http():
    response = None
    try:
        ## Ask for actual server time to keep rtc up to date
        response = ur.get(SERVER_URL)
        timestamp = response.headers.get('Date') # GMT timestamp
    except Exception as e:
        print(rtc.datetime(), "Error while getting Server-Time (HTTP): ", e)###
        timestamp = None
    finally:
        if response:
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
            print(rtc.datetime(), "Error while converting Time-Format (HTTP): ", e)
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

async def mqtt_task():
    global running
    while running:
        try:
            if tb_client is not None:
                tb_client.check_for_msg()
        except Exception as e:
            print(rtc.datetime(), 'MQTT error:', e)
        await asyncio.sleep_ms(200)
''' Error JSON:
    error_transmission = {"time": rtc.datetime(),
                          "place": "read_data"/"send_data"/"receive_time"/"wlanConnect",
                          "descr.": "Error while acquiring data: "/"Error while sending data: "...,
                          "e-Code": e}
'''


wdt.feed() # prevent wdt to restart the system
led.on()
led.off()

isconnected = network.WLAN(network.STA_IF).isconnected()
ipv4 = network.WLAN(network.STA_IF).ifconfig()[0]
wlan_status = network.WLAN(network.STA_IF).status()

if isconnected:
    print(rtc.datetime(), f'Connected to WLAN: {ipv4}')########################
    time.sleep(.5)
    blink_led(wlan_status)
    
    ## Ask for actual server time to keep rtc up to date
    rtc_isupdated = receive_time()

    # Try to create timers - use hardware timers if available, otherwise virtual timers
    try:
        data_timer = machine.Timer(1)
    except ValueError:
        data_timer = machine.Timer(-1)
    
    if secrets['per_dataacq']:
        data_timer.init(period=interval, mode=machine.Timer.PERIODIC, callback=read_data)
    else:
        data_timer.init(period=interval, mode=machine.Timer.ONE_SHOT, callback=read_data)
    
    try:
        rtc_update_timer = machine.Timer(2)
    except ValueError:
        rtc_update_timer = machine.Timer(-1)
    
    rtc_update_timer.init(period=2147483647, mode=machine.Timer.PERIODIC, callback=update_rtc) # ~24.8 days (max int32)

    def shutdown(reason=''):
        global running
        rtc_update_timer.deinit()
        data_timer.deinit()
        running = False
        if reason:
            print(rtc.datetime(), reason)

    async def main_loop():
        global running
        while True:
            if rp2.bootsel_button():
                shutdown('BOOTSEL gedrückt – Programm beendet.')
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
        task_mqtt = asyncio.create_task(mqtt_task())
        await asyncio.gather(task_pulse, task_main_loop, task_mqtt)

    running = True
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        shutdown('Programm manuell unterbrochen (Ctrl+C).')
        if tb_client is not None:
            try:
                tb_client.disconnect()
            except Exception:
                pass
else:
    print(rtc.datetime(), 'Failed WLAN-Connection:', CYW43_ERROR_CODES.get(wlan_status, "Unknown error code."))
    time.sleep(.5)
    blink_led(wlan_status)
    # Programmabbruch
