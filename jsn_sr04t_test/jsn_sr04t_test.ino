const int trigPin = 9;
const int echoPin = 8;

// Hardware blind zone is ~20–25 cm (transducer ringing). Soft floor is lower
// so short returns still print; treat <25 cm as rough, not precise.
const float MIN_CM = 5.0;
const float MAX_CM = 450.0;
const float RELIABLE_MIN_CM = 25.0;
const unsigned long ECHO_TIMEOUT_US = 30000; // ~5 m round-trip margin
const int NUM_SAMPLES = 7;                  // odd → clean median
const unsigned SAMPLE_GAP_MS = 60;          // let ringing settle

float readOnceCm() {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);
  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(trigPin, LOW);

  unsigned long duration = pulseIn(echoPin, HIGH, ECHO_TIMEOUT_US);
  if (duration == 0) {
    return NAN;
  }

  float cm = duration * 0.0343f / 2.0f;
  if (cm < MIN_CM || cm > MAX_CM) {
    return NAN;
  }
  return cm;
}

// Insertion-sort in place (N is tiny)
void sortAscending(float *a, int n) {
  for (int i = 1; i < n; i++) {
    float key = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > key) {
      a[j + 1] = a[j];
      j--;
    }
    a[j + 1] = key;
  }
}

// Median of valid samples; returns NAN if none valid
float readMedianCm(int *validOut) {
  float samples[NUM_SAMPLES];
  int valid = 0;

  for (int i = 0; i < NUM_SAMPLES; i++) {
    float cm = readOnceCm();
    if (!isnan(cm)) {
      samples[valid++] = cm;
    }
    delay(SAMPLE_GAP_MS);
  }

  *validOut = valid;
  if (valid == 0) {
    return NAN;
  }

  sortAscending(samples, valid);
  return samples[valid / 2];
}

void setup() {
  Serial.begin(9600);
  pinMode(trigPin, OUTPUT);
  pinMode(echoPin, INPUT);
  digitalWrite(trigPin, LOW);
  Serial.println(F("JSN-SR04T median filter ready"));
}

void loop() {
  int valid = 0;
  float cm = readMedianCm(&valid);

  if (isnan(cm)) {
    Serial.println(F("No valid echo"));
  } else {
    Serial.print(F("Distance: "));
    Serial.print(cm, 1);
    Serial.print(F(" cm  ("));
    Serial.print(valid);
    Serial.print('/');
    Serial.print(NUM_SAMPLES);
    Serial.print(F(" ok)"));
    if (cm < RELIABLE_MIN_CM) {
      Serial.print(F("  [near-field, rough]"));
    }
    Serial.println();
  }
}
