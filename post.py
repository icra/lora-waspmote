'''
  post a json string to the database server
'''
import requests
import json

def post(rebut):
  #convert the input json object to string
  rebut=json.dumps(rebut);

  #do the request
  print("Posting data...");
  r=requests.post('http://lora.h2793818.stratoserver.net/post.php',{'data':rebut});

  #print result
  print(r.status_code);
  print(r.text);
  return;
  
#test
#json string rebut del gateway
rebut={
  "id_sensor":1,
  "datetime":"2018-09-01 00:00",
  "temperatura1":15,
  "temperatura2":20,
  "temperatura3":25,
  "nivell":10,
  "overflow":0,
};
post(rebut)
