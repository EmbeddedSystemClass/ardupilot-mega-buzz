// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-
/*****************************************************************************
The init_ardupilot function processes everything we need for an in - air restart
	We will determine later if we are actually on the ground and process a
	ground start in that case.

*****************************************************************************/

#if CLI_ENABLED == ENABLED

// Functions called from the top-level menu
static int8_t	process_logs(uint8_t argc, const Menu::arg *argv);	// in Log.pde
static int8_t	setup_mode(uint8_t argc, const Menu::arg *argv);	// in setup.pde
static int8_t	test_mode(uint8_t argc, const Menu::arg *argv);		// in test.cpp
static int8_t	planner_mode(uint8_t argc, const Menu::arg *argv);	// in planner.pde

// This is the help function
// PSTR is an AVR macro to read strings from flash memory
// printf_P is a version of print_f that reads from flash memory
static int8_t	main_menu_help(uint8_t argc, const Menu::arg *argv)
{
	Serial.printf_P(PSTR("Commands:\n"
						 "  logs        log readback/setup mode\n"
						 "  setup       setup mode\n"
						 "  test        test mode\n"
						 "\n"
						 "Move the slide switch and reset to FLY.\n"
						 "\n"));
	return(0);
}

// Command/function table for the top-level menu.
static const struct Menu::command main_menu_commands[] PROGMEM = {
//   command		function called
//   =======        ===============
	{"logs",		process_logs},
	{"setup",		setup_mode},
	{"test",		test_mode},
	{"help",		main_menu_help},
	{"planner",		planner_mode}
};

// Create the top-level menu object.
MENU(main_menu, THISFIRMWARE, main_menu_commands);

// the user wants the CLI. It never exits
static void run_cli(void)
{
    // disable the failsafe code in the CLI
    timer_scheduler.set_failsafe(NULL);

    while (1) {
        main_menu.run();
    }
}

#endif // CLI_ENABLED

static void init_ardupilot()
{
    bool need_log_erase = false;

#if USB_MUX_PIN > 0 

    // on the APM2 board we have a mux thet switches UART0 between
    // USB and the board header. If the right ArduPPM firmware is
    // installed we can detect if USB is connected using the
    // USB_MUX_PIN
    pinMode(USB_MUX_PIN, INPUT);

    usb_connected = !digitalRead(USB_MUX_PIN);
    if (!usb_connected) {
        // USB is not connected, this means UART0 may be a Xbee, with
        // its darned bricking problem. We can't write to it for at
        // least one second after powering up. Simplest solution for
        // now is to delay for 1 second. Something more elegant may be
        // added later
        delay(1000);
    }
#endif

#if TELEMETRY_ON_SERIAL0 == 1   // we might put telemetry to Serial0 instead of Serial3, even without the MUX, 
        delay( 1000 ) ; 
#endif 

	// Console serial port
	//
	// The console port buffers are defined to be sufficiently large to support
	// the console's use as a logging device, optionally as the GPS port when
	// GPS_PROTOCOL_IMU is selected, and as the telemetry port.
	//
	// XXX This could be optimised to reduce the buffer sizes in the cases
	// where they are not otherwise required.
	//
	Serial.begin(SERIAL0_BAUD, 128, 128);

	// GPS serial port.
	//
	// XXX currently the EM406 (SiRF receiver) is nominally configured
	// at 57600, however it's not been supported to date.  We should
	// probably standardise on 38400.
	//
	// XXX the 128 byte receive buffer may be too small for NMEA, depending
	// on the message set configured.
	//
    // standard gps running
    Serial1.begin(38400, 128, 16);

	Serial.printf_P(PSTR("\n\nInit " THISFIRMWARE
						 "\n\nFree RAM: %u\n"),
                    memcheck_available_memory());

	//
	// Initialize Wire and SPI libraries
	//
#ifndef DESKTOP_BUILD
    I2c.begin();
    I2c.timeOut(5);
    // initially set a fast I2c speed, and drop it on first failures
    I2c.setSpeed(true);
#endif
    SPI.begin();
    SPI.setClockDivider(SPI_CLOCK_DIV16); // 1MHZ SPI rate
	//
	// Initialize the ISR registry.
	//
    isr_registry.init();

    //
	// Initialize the timer scheduler to use the ISR registry.
	//

    timer_scheduler.init( & isr_registry );

	//
	// Check the EEPROM format version before loading any parameters from EEPROM.
	//
    load_parameters();

    // keep a record of how many resets have happened. This can be
    // used to detect in-flight resets
    g.num_resets.set_and_save(g.num_resets+1);

	// init the GCS
	gcs0.init(&Serial);

#if USB_MUX_PIN > 0
    if (!usb_connected) {
        // we are not connected via USB, re-init UART0 with right
        // baud rate
        Serial.begin(map_baudrate(g.serial3_baud, SERIAL3_BAUD), 128, 128);
    }
#endif

// wack serial zero into the baud rate that we are supposed to use in Serial3
#if TELEMETRY_ON_SERIAL0 == 1 
         Serial.begin(57600, 128, 128); //TODO DONT HARDCODE THIS, BUT DONT MAKE IT SERIAL0_BAUD OR SERIAL3_BAUD it may clash! 
#endif 

#if SERIAL3_INIT == 1 
    // we have a 2nd serial port, possibly for telemetry, or maybe for other stuff 
        Serial3.begin(map_baudrate(g.serial3_baud, SERIAL3_BAUD), 128, 128);
#endif
#if TELEMETRY_ON_SERIAL0 != 1  && SERIAL3_INIT == 1 
     // ok, so we're doing hte classic APM1 thing for telemetry.. 
	gcs3.init(&Serial3);
#endif


	mavlink_system.sysid = g.sysid_this_mav;

#if LOGGING_ENABLED == ENABLED
	DataFlash.Init(); 	// DataFlash log initialization
    if (!DataFlash.CardInserted()) {
        gcs_send_text_P(SEVERITY_LOW, PSTR("No dataflash card inserted"));
        g.log_bitmask.set(0);
    } else if (DataFlash.NeedErase()) {
        gcs_send_text_P(SEVERITY_LOW, PSTR("ERASING LOGS"));
		do_erase_logs();
    }
	if (g.log_bitmask != 0) {
		DataFlash.start_new_log();
	}
#endif

#if HIL_MODE != HIL_MODE_ATTITUDE

#if CONFIG_ADC == ENABLED
    adc.Init(&timer_scheduler);      // APM ADC library initialization
#endif

	barometer.init(&timer_scheduler);

	if (g.compass_enabled==true) {
        compass.set_orientation(MAG_ORIENTATION);							// set compass's orientation on aircraft
		if (!compass.init()) {
            Serial.println_P(PSTR("Compass initialisation failed!"));
            g.compass_enabled = false;
        } else {
            dcm.set_compass(&compass);
            compass.get_offsets();						// load offsets to account for airframe magnetic interference
            compass.null_offsets_enable();
        }
	}
#endif

<<<<<<< HEAD
#if LOGGING_ENABLED == ENABLED
	DataFlash.Init(); 	// DataFlash log initialization
#endif


	pinMode(C_LED_PIN, OUTPUT);			// GPS status LED
	pinMode(A_LED_PIN, OUTPUT);			// GPS status LED
	pinMode(B_LED_PIN, OUTPUT);			// GPS status LED

  
          #if EXTRA_GPS_DEBUG == 1
          digitalWrite(A_LED_PIN, 1 );
          delay(1000);        
          #endif  
          
=======
>>>>>>> origin/master
	// Do GPS init
	g_gps = &g_gps_driver;
	g_gps->init();			// GPS Initialization
        g_gps->callback = mavlink_delay;
        g_gps->update();
        	
          #if EXTRA_GPS_DEBUG == 1
          digitalWrite(A_LED_PIN, 0 );
          delay(500);        
          digitalWrite(B_LED_PIN, 1 );
          delay(1000);        
          #endif 
          
        #if EXTRA_GPS == ENABLED
  	// Do other GPS init
	g_gps2 = &g_gps_driver2;
	g_gps2->init();			// EXTRA GPS Initialization
        g_gps2->callback = mavlink_delay;
        g_gps2->update();	
        #endif
        
          #if EXTRA_GPS_DEBUG == 1
          digitalWrite(B_LED_PIN, 0 );
          #endif

 
	//mavlink_system.sysid = MAV_SYSTEM_ID;				// Using g.sysid_this_mav
	mavlink_system.compid = 1;	//MAV_COMP_ID_IMU;   // We do not check for comp id
	mavlink_system.type = MAV_FIXED_WING;

	rc_override_active = APM_RC.setHIL(rc_override);		// Set initial values for no override

    RC_Channel::set_apm_rc( &APM_RC ); // Provide reference to RC outputs.
	init_rc_in();		// sets up rc channels from radio
	init_rc_out();		// sets up the timer libs

#if SLIDE_SWITCH_PIN > 0
	pinMode(SLIDE_SWITCH_PIN, INPUT);	// To enter interactive mode
#endif
#if CONFIG_PUSHBUTTON == ENABLED
	pinMode(PUSHBUTTON_PIN, INPUT);		// unused
#endif
#if CONFIG_RELAY == ENABLED
	DDRL |= B00000100;					// Set Port L, pin 2 to output for the relay
#endif

#if FENCE_TRIGGERED_PIN > 0
    pinMode(FENCE_TRIGGERED_PIN, OUTPUT);
    digitalWrite(FENCE_TRIGGERED_PIN, LOW);
#endif

    /*
      setup the 'main loop is dead' check. Note that this relies on
      the RC library being initialised.
     */
    timer_scheduler.set_failsafe(failsafe_check);


	// If the switch is in 'menu' mode, run the main menu.
	//
	// Since we can't be sure that the setup or test mode won't leave
	// the system in an odd state, we don't let the user exit the top
	// menu; they must reset in order to fly.
	//
#if CLI_ENABLED == ENABLED && CLI_SLIDER_ENABLED == ENABLED
	if (digitalRead(SLIDE_SWITCH_PIN) == 0) {
		digitalWrite(A_LED_PIN,LED_ON);		// turn on setup-mode LED
		Serial.printf_P(PSTR("\n"
							 "Entering interactive setup mode...\n"
							 "\n"
							 "If using the Arduino Serial Monitor, ensure Line Ending is set to Carriage Return.\n"
							 "Type 'help' to list commands, 'exit' to leave a submenu.\n"
							 "Visit the 'setup' menu for first-time configuration.\n"));
        Serial.println_P(PSTR("\nMove the slide switch and reset to FLY.\n"));
        run_cli();
	}
#else
    Serial.printf_P(PSTR("\nPress ENTER 3 times to start interactive setup\n\n"));
#endif // CLI_ENABLED

	// read in the flight switches
	update_servo_switches();

	if (ENABLE_AIR_START == 1) {
		// Perform an air start and get back to flying
		gcs_send_text_P(SEVERITY_LOW,PSTR("<init_ardupilot> AIR START"));

		// Get necessary data from EEPROM
		//----------------
		//read_EEPROM_airstart_critical();
#if HIL_MODE != HIL_MODE_ATTITUDE
		imu.init(IMU::WARM_START, mavlink_delay, flash_leds, &timer_scheduler);
		dcm.set_centripetal(1);
#endif

		// This delay is important for the APM_RC library to work.
		// We need some time for the comm between the 328 and 1280 to be established.
		int old_pulse = 0;
		while (millis()<=1000 && (abs(old_pulse - APM_RC.InputCh(g.flight_mode_channel)) > 5 ||
					APM_RC.InputCh(g.flight_mode_channel) == 1000 ||
					APM_RC.InputCh(g.flight_mode_channel) == 1200)) {
			old_pulse = APM_RC.InputCh(g.flight_mode_channel);
			delay(25);
		}
		GPS_enabled = false;
		g_gps->update();
		if (g_gps->status() != 0 || HIL_MODE != HIL_MODE_DISABLED)	GPS_enabled = true;

		if (g.log_bitmask & MASK_LOG_CMD)
			Log_Write_Startup(TYPE_AIRSTART_MSG);
		reload_commands_airstart();		// Get set to resume AUTO from where we left off

	}else {
		startup_ground();
		if (g.log_bitmask & MASK_LOG_CMD)
			Log_Write_Startup(TYPE_GROUNDSTART_MSG);
	}

    set_mode(MANUAL);

	// set the correct flight mode
	// ---------------------------
	reset_control_switch();
}

#if EXTRA_GPS == ENABLED
 void use_best_gps(void){
  
   static int _active = 1;   // default to primary GPS on Serial1 first  
   #ifdef  EXTRA_GPS_DEBUG  
   static int _which = 0; // primary GPS defaults to A LED being OFF. alternate GPS turns this LED on.! 
   #endif
   
   int G1 = g_gps->num_sats; // currently active
   int G3 = g_gps2->num_sats;  // currently inactive/backup
     
    // quick, decide which GPS is better? 
    // for now, we use the number of sattelites, but we *could* also use GDOP values 
    // or similar, if the appropriate module/s supply this info
    if ( G3 > G1 ) { 
      
    #ifdef  EXTRA_GPS_DEBUG  
      if ( _which == 0 ) {  _which=1; _active=3 ; } else { _which=0;_active = 1 ; } // which serial are we switching to... Serial1 or Serial3? 
      Serial.print("GPS FLIP! Now using Serial");
      Serial.print(_active);
      Serial.print(" ( Sats: ");
      Serial.print((int)G3);
      Serial.println(" )");
   #endif         
           
      //switch the pointers for g_gps, and g_gps2, so we go to the other GPS! 
      g_gpscurrent = g_gps; 
      g_gps = g_gps2;
      g_gps2 = g_gpscurrent;
           
    #ifdef EXTRA_GPS_DEBUG  
      //indicate the GPS toggle state with an extra LED 
      digitalWrite(A_LED_PIN, _which );
    #endif  
        } else {
    #ifdef  EXTRA_GPS_DEBUG  
      Serial.print("GPS Sats? active: ");
      Serial.print( (int)G1);
      Serial.print(" inactive: ");
      Serial.println( (int)G3);
    #endif
        }  
}
#endif

//********************************************************************************
//This function does all the calibrations, etc. that we need during a ground start
//********************************************************************************
static void startup_ground(void)
{
    set_mode(INITIALISING);

	gcs_send_text_P(SEVERITY_LOW,PSTR("<startup_ground> GROUND START"));

	#if(GROUND_START_DELAY > 0)
		gcs_send_text_P(SEVERITY_LOW,PSTR("<startup_ground> With Delay"));
		delay(GROUND_START_DELAY * 1000);
	#endif

	// Makes the servos wiggle
	// step 1 = 1 wiggle
	// -----------------------
	demo_servos(1);

	//IMU ground start
	//------------------------
    //
	startup_IMU_ground();

	// read the radio to set trims
	// ---------------------------
	trim_radio();		// This was commented out as a HACK.  Why?  I don't find a problem.

	// Save the settings for in-air restart
	// ------------------------------------
	//save_EEPROM_groundstart();

	// initialize commands
	// -------------------
	init_commands();

    // Read in the GPS - see if one is connected
    GPS_enabled = false;
	for (byte counter = 0; ; counter++) {
		g_gps->update();
		if (g_gps->status() != 0 || HIL_MODE != HIL_MODE_DISABLED){
			GPS_enabled = true;
			break;
		}

		if (counter >= 2) {
			GPS_enabled = false;
			break;
	    }
	}

	// Makes the servos wiggle - 3 times signals ready to fly
	// -----------------------
	demo_servos(3);

	gcs_send_text_P(SEVERITY_LOW,PSTR("\n\n Ready to FLY."));
}

static void set_mode(byte mode)
{
	if(control_mode == mode){
		// don't switch modes if we are already in the correct mode.
		return;
	}
	if(g.auto_trim > 0 && control_mode == MANUAL)
		trim_control_surfaces();

	control_mode = mode;
	crash_timer = 0;

	switch(control_mode)
	{
		case INITIALISING:
		case MANUAL:
		case CIRCLE:
		case STABILIZE:
		case FLY_BY_WIRE_A:
		case FLY_BY_WIRE_B:
			break;

		case AUTO:
			update_auto();
			break;

		case RTL:
			do_RTL();
			break;

		case LOITER:
			do_loiter_at_location();
			break;

		case GUIDED:
			set_guided_WP();
			break;

		default:
			do_RTL();
			break;
	}

	if (g.log_bitmask & MASK_LOG_MODE)
		Log_Write_Mode(control_mode);
}

static void check_long_failsafe()
{
	// only act on changes
	// -------------------
	if(failsafe != FAILSAFE_LONG  && failsafe != FAILSAFE_GCS){
		if(rc_override_active && millis() - rc_override_fs_timer > FAILSAFE_LONG_TIME) {
			failsafe_long_on_event(FAILSAFE_LONG);
		}
		if(! rc_override_active && failsafe == FAILSAFE_SHORT && millis() - ch3_failsafe_timer > FAILSAFE_LONG_TIME) {
			failsafe_long_on_event(FAILSAFE_LONG);
		}
		if(g.gcs_heartbeat_fs_enabled && millis() - rc_override_fs_timer > FAILSAFE_LONG_TIME) {
			failsafe_long_on_event(FAILSAFE_GCS);
		}
	} else {
		// We do not change state but allow for user to change mode
		if(failsafe == FAILSAFE_GCS && millis() - rc_override_fs_timer < FAILSAFE_SHORT_TIME) failsafe = FAILSAFE_NONE;
		if(failsafe == FAILSAFE_LONG && rc_override_active && millis() - rc_override_fs_timer < FAILSAFE_SHORT_TIME) failsafe = FAILSAFE_NONE;
		if(failsafe == FAILSAFE_LONG && !rc_override_active && !ch3_failsafe) failsafe = FAILSAFE_NONE;
	}
}

static void check_short_failsafe()
{
	// only act on changes
	// -------------------
	if(failsafe == FAILSAFE_NONE){
		if(ch3_failsafe) {					// The condition is checked and the flag ch3_failsafe is set in radio.pde
			failsafe_short_on_event(FAILSAFE_SHORT);
		}
	}

	if(failsafe == FAILSAFE_SHORT){
		if(!ch3_failsafe) {
			failsafe_short_off_event();
		}
	}
}


static void startup_IMU_ground(void)
{
#if HIL_MODE != HIL_MODE_ATTITUDE
    gcs_send_text_P(SEVERITY_MEDIUM, PSTR("Warming up ADC..."));
 	mavlink_delay(500);

	// Makes the servos wiggle twice - about to begin IMU calibration - HOLD LEVEL AND STILL!!
	// -----------------------
	demo_servos(2);
    gcs_send_text_P(SEVERITY_MEDIUM, PSTR("Beginning IMU calibration; do not move plane"));
	mavlink_delay(1000);

	imu.init(IMU::COLD_START, mavlink_delay, flash_leds, &timer_scheduler);
	imu.init_accel(mavlink_delay, flash_leds);
	dcm.set_centripetal(1);
    dcm.matrix_reset();

	// read Baro pressure at ground
	//-----------------------------
	init_barometer();

    if (g.airspeed_enabled == true) {
        // initialize airspeed sensor
        // --------------------------
        zero_airspeed();
        gcs_send_text_P(SEVERITY_LOW,PSTR("<startup_ground> zero airspeed calibrated"));
    } else {
        gcs_send_text_P(SEVERITY_LOW,PSTR("<startup_ground> NO airspeed"));
    }

#endif // HIL_MODE_ATTITUDE

	digitalWrite(A_LED_PIN, LED_OFF);
	digitalWrite(B_LED_PIN, LED_ON);		// Set LED B high to indicate IMU ready
	digitalWrite(C_LED_PIN, LED_OFF);
}


// LED C for primary GPS, LED A for "alternate" GPS
static void update_GPS_light(void)
{
	// GPS LED on if we have a fix or Blink GPS LED if we are receiving data
	// ---------------------------------------------------------------------
	switch (g_gps->status()) {
		case(2):
			digitalWrite(C_LED_PIN, LED_ON);  //Turn LED C on when gps has valid fix.
			break;

		case(1):
			if (g_gps->valid_read == true){
				GPS_light = !GPS_light; // Toggle light on and off to indicate gps messages being received, but no GPS fix lock
				if (GPS_light){
					digitalWrite(C_LED_PIN, LED_OFF);
				} else {
					digitalWrite(C_LED_PIN, LED_ON);
				}
				g_gps->valid_read = false;
			}
			break;

		default:
			digitalWrite(C_LED_PIN, LED_OFF);
			break;
	}

}


static void resetPerfData(void) {
	mainLoop_count 			= 0;
	G_Dt_max 				= 0;
	dcm.gyro_sat_count 		= 0;
	imu.adc_constraints 	= 0;
	dcm.renorm_sqrt_count 	= 0;
	dcm.renorm_blowup_count = 0;
	gps_fix_count 			= 0;
	pmTest1					= 0;
	perf_mon_timer 			= millis();
}


/*
  map from a 8 bit EEPROM baud rate to a real baud rate
 */
static uint32_t map_baudrate(int8_t rate, uint32_t default_baud)
{
    switch (rate) {
    case 1:    return 1200;
    case 2:    return 2400;
    case 4:    return 4800;
    case 9:    return 9600;
    case 19:   return 19200;
    case 38:   return 38400;
    case 57:   return 57600;
    case 111:  return 111100;
    case 115:  return 115200;
    }
    Serial.println_P(PSTR("Invalid SERIAL3_BAUD"));
    return default_baud;
}


#if USB_MUX_PIN > 0
static void check_usb_mux(void)
{
    bool usb_check = !digitalRead(USB_MUX_PIN);
    if (usb_check == usb_connected) {
        return;
    }

    // the user has switched to/from the telemetry port
    usb_connected = usb_check;
    if (usb_connected) {
        Serial.begin(SERIAL0_BAUD, 128, 128);
    } else {
        Serial.begin(map_baudrate(g.serial3_baud, SERIAL3_BAUD), 128, 128);
    }
}
#endif


/*
  called by gyro/accel init to flash LEDs so user
  has some mesmerising lights to watch while waiting
 */
void flash_leds(bool on)
{
    digitalWrite(A_LED_PIN, on?LED_OFF:LED_ON);
    digitalWrite(C_LED_PIN, on?LED_ON:LED_OFF);
}
