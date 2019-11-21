/*
  Waspmote llegeix:
    1. Sensors temperatura (3 DS1820)
    2. Sensor overflow (cso) capacitiu miocrocom
    3. Sensor distància ultrasons maxbotix
  Després envia les lectures via LoRaWAN (libelium)
*/

#include<WaspLoRaWAN.h>

/*****************/
/* CONFIGURATION */
/*****************/

//constants
#define APP_EUI             "0102030405060708"                 /*app identifier (set in gateway conf)*/
#define APP_KEY             "01020304050607080910111213141516" //app password   (set in gateway conf)
#define DEBUG               true               /*usb debugging active*/
#define SLEEP_INTERVAL_DRY  "00:00:02:00"      /*deep sleep interval (dry weather)*/
#define SLEEP_INTERVAL_RAIN "00:00:01:00"      /*deep sleep interval when it is raining*/
#define NUM_LOOPS_DRY       2                  /*lectures seguides abans de dormir SLEEP_INTERVAL_DRY*/
#define NUM_LOOPS_RAIN      3                  /*lectures seguides abans de dormir SLEEP_INTERVAL_RAIN*/
#define MSG_LENGTH          200                /*max length json message in bytes*/
#define PIN_MICROCOM        DIGITAL1           /*pin microcom (cso detection)*/
#define PIN_T1              DIGITAL4           /*pin sensor temperatura 1*/
#define PIN_T2              DIGITAL6           /*pin sensor temperatura 2*/
#define PIN_T3              DIGITAL8           /*pin sensor temperatura 3*/
#define MB_READINGS         10                 /*maxbotix readings each loop and averaged*/
#define TIMEOUT             1000               /*ms maxbotix serial read timeout*/

//variables
char           wasp_id[5];              /*waspmote id (4 chars)*/
char           device_eui[17];          /*000000000000 + waspmote id (16 chars)*/
bool           chargeState     = false; /*is battery charging?*/
unsigned int   paquets_enviats = 0;     /*number of sent packets (tx)*/
unsigned int   paquets_rebuts  = 0;     /*number of ackd packets (rx)*/
bool           its_raining     = false; /*it is raining?*/
unsigned short num_loops       = 0;     /*lectures que es faran abans de dormir*/
unsigned short num_loop_actual = 0;     /*lectura actual abans de dormir*/
int8_t         error           = -1;    //error variable

void setup(){
  //get wasp id (2 first bytes in hexadecimal)
  Utils.readSerialID();
  snprintf(wasp_id,    10, "%.2x%.2x", _serial_id[0], _serial_id[1]);

  //set device eui using wasp id
  snprintf(device_eui, 17, "000000000000%.2x%.2x", _serial_id[0], _serial_id[1]);

  //init USB, show waspmote id
  if(DEBUG){
    USB.ON();
    USB.print(F("Waspmote id: "));
    USB.println(wasp_id);
    USB.print(F("device eui: "));
    USB.println(device_eui);
  }

  //config microcom capacitiu detector cso overflows
  pinMode(PIN_MICROCOM,INPUT);

  //config maxbotix sensor ultrasons distance (nivell)
  Utils.setMuxAux1();
  beginSerial(9600,1);

  //init power pins
  PWR.setSensorPower(SENS_5V,  SENS_ON);
  PWR.setSensorPower(SENS_3V3, SENS_ON);

  //setup lorawan chip
  lorawan_setup();

  //show sleep duration
  if(DEBUG){
    USB.println(F("--------------------------------"));
    USB.print(F("SLEEP_INTERVAL_DRY:  "));USB.println(SLEEP_INTERVAL_DRY);
    USB.print(F("SLEEP_INTERVAL_RAIN: "));USB.println(SLEEP_INTERVAL_RAIN);
    USB.println(F("--------------------------------"));
  }

  //wait 1 second
  delay(1000);
}

void loop(){
  //read battery level and volts
  int   battery = PWR.getBatteryLevel(); //%
  float volts   = PWR.getBatteryVolts(); //V

  if(DEBUG){
    //show remaining battery level
    USB.print(F("Battery Level: "));
    USB.print(battery);
    USB.print(F(" %"));

    //show battery Volts
    USB.print(F(" | Battery (Volts): "));
    USB.print(volts);
    USB.println(F(" V"));

    //show battery charging state. This is valid for both USB and Solar panel
    //if any of those ports are used the charging state will be true
    chargeState = PWR.getChargingState();
    USB.print(F("Battery charging state: "));
    if(chargeState){
      USB.println(F("Battery is charging"));
    }else{
      USB.println(F("Battery is not charging"));
    }

    USB.println(F("--------------------------------"));
  }

  //read DS1820 temperature (ºC)
  if(DEBUG) USB.print(F("Reading temperature (ºC)... "));
  float temp1 = Utils.readTempDS1820(PIN_T1); if(DEBUG){ USB.print(  temp1); USB.print(", "); }
  float temp2 = Utils.readTempDS1820(PIN_T2); if(DEBUG){ USB.print(  temp2); USB.print(", "); }
  float temp3 = Utils.readTempDS1820(PIN_T3); if(DEBUG){ USB.println(temp3); }

  //read microcom overflow detector
  if(DEBUG) USB.print(F("Reading cso overflows (true/false)..."));
  bool cso_detected = digitalRead(PIN_MICROCOM); //true/false overflow

  //if cso detected --> it is raining
  its_raining = cso_detected;

  if(DEBUG){
    USB.print(cso_detected);
    if(its_raining){
      USB.println(F(" [RAINING (or microcom sensor unplugged)]"));
    }else{
      USB.println(F(" [NOT RAINING]"));
    }
  }

  //read maxbotix distance sensor n times
  if(DEBUG) USB.println(F("Reading distance (cm)..."));

  unsigned short distances[MB_READINGS];
  for(int i=0;i<MB_READINGS;i++){
    distances[i]=0;
    unsigned long timeout = millis();
    while(distances[i]==0){
      if(millis()-timeout > TIMEOUT) break;
      distances[i] = readSensorSerial();
    }
    if(DEBUG){
      USB.print(distances[i]);
      USB.print(i<MB_READINGS-1 ? ",":": ");
    }
  }

  //readings done: switch off power
  PWR.setSensorPower(SENS_3V3,SENS_OFF);
  PWR.setSensorPower(SENS_5V,SENS_OFF);

  //compute distances measured average
  unsigned short distance = computeAverage(distances,10);
  if(DEBUG) USB.println(distance);

  //construct string json with all readings done so far
  char message[MSG_LENGTH];

  construct_json_message(
    message,
    temp1, temp2, temp3,
    cso_detected,
    distance,
    battery,
    volts
  );

  //send message
  lorawan_send_message(message);

  //add 1 to current loop counter
  num_loop_actual++;

  //set the number of loops done before sleeping
  num_loops = its_raining ? NUM_LOOPS_RAIN : NUM_LOOPS_DRY;

  if(DEBUG){
    USB.print("loop before deep sleep: ");
    USB.print(num_loop_actual);
    USB.print("/");
    USB.println(num_loops);
    USB.println(F("============================="));
  }

  //check if we can start deep sleep
  if(num_loop_actual >= num_loops){
    if(DEBUG){
      USB.print(F("Entering deep sleep... "));
      USB.println(its_raining ? SLEEP_INTERVAL_RAIN : SLEEP_INTERVAL_DRY);
    }

    //reset num loop actual
    num_loop_actual = 0;

    //start deep sleep
    PWR.deepSleep(
      its_raining ? SLEEP_INTERVAL_RAIN : SLEEP_INTERVAL_DRY,
      RTC_OFFSET, RTC_ALM1_MODE1, ALL_OFF
    );

    //end deep sleep
    if(DEBUG){
      USB.println(F("wake up!"));
      USB.println();
    }
  }

  //call setup() to switch on power again
  setup();
}

//read maxbotix distance sensor
unsigned short readSensorSerial() {
  char buf[5]; //reserva 5 bytes "R000\0"
  serialFlush(1);

  //wait for incoming 'R' character or timeout
  unsigned long timeout = millis();
  while(!serialAvailable(1) || serialRead(1) != 'R'){
    if(millis()-timeout > TIMEOUT) break;
  }

  //read distance
  for(int i=0; i<4; i++){
    while(!serialAvailable(1)){
      if(millis()-timeout > TIMEOUT) break;
    }
    buf[i]=serialRead(1);
  }
  buf[4]='\0'; //add string terminating character
  return atoi(buf);
}

//compute average of distances read from maxbotix sensor
unsigned short computeAverage(unsigned short *distances, int length){
  int sum=0;
  int l = length; //l is length that can decrease if readings are 0
  for(int i=0;i<length;i++){
    if(distances[i]==0) l--;
    sum += distances[i];
  }
  return (l==0? 0 : sum/l);
}

//construct json string message
void construct_json_message(
    char *message,
    float temp1, float temp2, float temp3,
    bool cso_detected,
    unsigned short distance,
    int battery, float volts
  ){

  //use dtostrf() to convert from float to string:
  //first '1' refers to minimum width
  //second '1' refers to number of decimals
  char t1[6]; dtostrf(temp1,1,1,t1);
  char t2[6]; dtostrf(temp2,1,1,t2);
  char t3[6]; dtostrf(temp3,1,1,t3);

  //estructura json: {wasp_id,t1,t2,t3,cso_detected,distance}
  snprintf(message, MSG_LENGTH,
    "{wid:\"%s\",T:[%s,%s,%s],cso:%d,d:%d,bat:%d,tx:%d}",
    wasp_id,
    t1, t2, t3,
    cso_detected,
    distance,
    battery,
    paquets_enviats++
  );
}

//setup lorawan connection
void lorawan_setup(){
  //1. switch lorawan on
  error = LoRaWAN.ON(SOCKET0);
  if(error==0){ USB.println(F("1. Switch LoRaWAN ON OK"));
  }else{        USB.print(F("1. Switch LoRaWAN ON error = "));
                USB.println(error, DEC);
  }

  //2. set device EUI
  error = LoRaWAN.setDeviceEUI(device_eui);
  if(error==0){ USB.println(F("2. Device EUI set OK"));
  }else{        USB.print(F("2. Device EUI set error = "));
                USB.println(error, DEC);
  }

  //3. Set Application EUI
  error = LoRaWAN.setAppEUI(APP_EUI);
  if(error==0){ USB.println(F("3. Application EUI set OK"));
  }else{        USB.print(F("3. Application EUI set error = "));
                USB.println(error, DEC);
  }

  //4. Set Application Session Key
  error = LoRaWAN.setAppKey(APP_KEY);
  if(error==0){ USB.println(F("4. Application Key set OK"));
  }else{        USB.print(F("4. Application Key set error = "));
                USB.println(error, DEC);
  }

  //5. Join OTAA to negotiate keys with the server
  error = LoRaWAN.joinOTAA();
  if(error==0){ USB.println(F("5. Join network OK"));
  }else{        USB.print(F("5. Join network error = "));
                USB.println(error, DEC);
  }

  //6. Save configuration
  error = LoRaWAN.saveConfig();
  if(error==0){ USB.println(F("6. Save configuration OK"));
  }else{        USB.print(F("6. Save configuration error = "));
                USB.println(error, DEC);
  }

  // 7. Switch off
  error = LoRaWAN.OFF(SOCKET0);
  if(error==0){ USB.println(F("7. Switch LoRaWAN OFF OK"));
  }else{        USB.print(F("7. Switch LoRaWAN OFF error = "));
                USB.println(error, DEC);
  }

  /*
  Module configured.
  After joining through OTAA, the module and the network exchanged the Network
  Session Key and the Application Session Key which are needed to perform
  communications. After that, 'ABP mode' is used to join the network and send
  messages after powering on the module
  */
}

//send message via lorawan
void lorawan_send_message(char *message){
  //1. switch lorawan on
  error = LoRaWAN.ON(SOCKET0);
  if(DEBUG){
    if(error==0){
      USB.println(F("Switch LoRaWAN ON: OK"));
    }else{
      USB.print(F("Switch LoRaWAN ON: error = "));
      USB.println(error, DEC);
    }
  }

  //2. join network
  error = LoRaWAN.joinABP();
  if(error==0) {
    if(DEBUG) USB.println(F("Join network OK"));

    //sendConfirmed(port, data)
    /*port: lorawan port to use in backend: from 1 to 223*/

    char hexstring[MSG_LENGTH];
    convert_json_to_hexstring(message, hexstring);
    error = LoRaWAN.sendConfirmed(3, hexstring);
    /* Error messages:
     * '6' : Module hasn't joined a network
     * '5' : Sending error
     * '4' : Error with data length
     * '2' : Module didn't response
     * '1' : Module communication error
    **/

    //if ACK is received
    if(error==0) paquets_rebuts++;

    if(DEBUG){
      if(error==0){
        USB.println(F("Send Confirmed packet OK"));
        if(LoRaWAN._dataReceived==true){
          USB.print(F("   There's data on port number "));
          USB.print(LoRaWAN._port,DEC);
          USB.print(F(".\r\n   Data: "));
          USB.println(LoRaWAN._data);
        }
      }else{
        USB.print(F("Send Confirmed packet error = "));
        USB.println(error, DEC);
      }
    }
  }else{
    if(DEBUG){
      //show error joining network via ABP
      USB.print(F("Join network error = "));
      USB.println(error, DEC);
    }
  }

  //4. switch off
  error = LoRaWAN.OFF(SOCKET0);
  if(DEBUG){
    if(error==0){
      USB.println(F("Switch LoRaWAN OFF OK"));
    }else{
      USB.print(F("Switch LoRaWAN OFF error = "));
      USB.println(error, DEC);
    }
  }
}

//transform ascii string to hexadecimal string
//for example: "hola" to "686f6c61"
void convert_json_to_hexstring(char *message, char *hexstring){
  //char  buffer1[] = "hola";   //ascii "hola"
  uint8_t buffer2[MSG_LENGTH];  //bytes {0x68 0x6f 0x6c 61}

  //clear buffer hexstring
  for(int i=0;i<MSG_LENGTH;i++){
    hexstring[i]=0x0;
  }

  //get length of message
  uint16_t size = strlen(message);
  if(DEBUG){
    USB.print("Length of message: ");
    USB.println(strlen(message));
    USB.println(message);
  }

  //convert char to int (copy also '\0')
  for(int i=0; i<=size; i++){
    buffer2[i] = (int)message[i]; //convert char to int
    if(DEBUG){
      continue; //view byte per byte disabled
      USB.print(i);
      USB.print(" ");
      USB.print(message[i]);
      USB.print(" ");
      USB.print(buffer2[i]);
      USB.print(" ");
      USB.println(buffer2[i],HEX);
    }
  }

  //convert from {0x48 0x65 0x6C ...} to "48656C..."
  Utils.hex2str(buffer2, hexstring, size);
  if(DEBUG){
    USB.print("Length of hexstring: ");
    USB.println(strlen(hexstring));
    USB.println(hexstring);
  }
}

//do nothing (for errors)
void do_nothing(){
  while(true){
    delay(10000);
  }
}
