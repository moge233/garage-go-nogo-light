;
; PingSensor5.asm
;
; Created: 3/14/2019 5:49:43 PM
; Author : Matt
;

.include "m2560def.inc"
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Vector Interrupt Table
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
.org			0x0000					; RESET Vector
jmp				RESET					;

.org			0x002E					; Timer0 Overflow Interrupt Vector
jmp				ISR_TOV0				;

.org			0x0052					; Inputer Capture 4 Interrupt
jmp				ISR_TIMER4_CAPT			;

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Define some names for common registers we will use 
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
.def			TEMP = r16				; r16 will be our temporary register 
.def			CAPTURE_LOW = r18		; r18 will store our low counter value when we capture input
.def			CAPTURE_HIGH = r19		; r19 will store our high counter value when we capture input
.def			TOV0_FLAG = r20			; This will allow our sensor to take measurements at a specific interval
										; 0x00 ==> Wait for timer overflow then start measurement
										; 0x01 ==> We have received ICR4 interrupt, now wait for timer overflow
										;		   and then clear this flag and restart the main loop
.def			IC4_FLAG = r21			; r22 will hold our IC4_FLAG value
										; 0x01 ==> we caught rising edge from the sensor
										; 0x02 ==> we caught falling edge from the sesor

RESET:
clr		IC4_FLAG						; Make sure our IC4_FLAG register is clear to start

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Set up the stack by pointing the end of SRAM (the stack grows down toward lower addresses)
; This means our stack pointer must be 2 bytes, in order to reach every memory location
; we will use LOW() and HIGH() to move the end of SRAM (SRAMEND) into the low and high bytes of SP respectively
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
ldi		TEMP, low(RAMEND)				; move the low byte of RAMEND into r16
out		SPL, TEMP						; move the low byte of RAMEND (r16) into the low byte of SP
ldi		TEMP, high(RAMEND)				; move the high byte of RAMEND into r16
out		SPH, TEMP						; move the high byte of RAMEND (r16) into the high byte of SP
clr		TEMP							; clear the contents of r16

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Set PORTA as outputs
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
ldi		TEMP, 0x03						;
out		DDRA, TEMP						; set PORTA1:0 as output
clr		TEMP							;
out		PORTA, TEMP						; write all outputs low

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Set up Timer0 Overflow interrupt
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
ldi		TEMP, (1 << CS02) | (1 << CS00)	; Set clk to be sysclk / 1024.  We OR the individual bits together
										; to set each bit in the register.  
out		TCCR0B, TEMP					;
ldi		TEMP, (1 << TOV0)				;
out		TIFR0, TEMP						; clear pending interrupts flag
ldi		TEMP, (1 << TOIE1)				;
sts		TIMSK0, TEMP					;

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; Setup Input Capture Interrupt 4 (ICP4) on PORTL0
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
ldi		TEMP, (1 << ICNC4) | (1 << ICES4) | (1 << CS40) ; 1/1 prescaler, rising edge detection,
														; noise cancellation
sts		TCCR4B, TEMP					; TCCR4B = 0b11000001
ldi		TEMP, (1 << ICF4)				; write a 1 to ICF4 to clear any pending interrupts that may be there
sts		TIFR4, TEMP						;
ldi		TEMP, (1 << ICIE4)				; Input Capture Interrupt Enable 4
sts		TIMSK4, TEMP					;


MAIN_LOOP:

	; First we will enable global interrupts to allow the Timer0 Overflow Interrupt to occur
	sei
	OVF1:
	cpi		TOV0_FLAG, 0x00				; is the TOV0 flag still 0?
	breq	OVF1						; if so, keep waiting for it

	; Once we receive our first timer overflow interrupt, we will send an output to our pulse sensor
	; and then set the pin to input and wait for the response pulse from the sensor
	cli
	rcall	DISABLE_TOV0				;
	rcall	SET_DDRL0_OUTPUT			; First set the sensor in/out pin as an output
	rcall	PULSE_OUTPUT_PL0			; Send a pulse to the sensor 
	rcall	SET_DDRL0_INPUT				; Change the sensor pin to an input

	; Now enable global interrupts and wait for the first rising edge of the pulse from the sensor
	sei									; enable global interrupts
	WAIT_FOR_RISING_EDGE:
	cpi		IC4_FLAG, 0x01				; check our interrupt flag
	brne	WAIT_FOR_RISING_EDGE		; If we didn't encounter an interrupt, keep waiting

	;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
	; We received a rising edge interrupt 
	;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~		

	; Disable global interrupts again so we can change the detection method of our input capture interrupt
	; from RISING EDGE DETECTION to FALLING EDGE DETECTION
	cli									; disable global interrupts to change edge detection
	rcall	SET_FALLING_EDGE_DETECTION	; change edge detection method

	; Reenable global interrupts and wait for the falling edge of the response pulse from the sensor
	sei									; 
	WAIT_FOR_FALLING_EDGE:
	cpi		IC4_FLAG, 0x02				; check the interrupt flag again
	brne	WAIT_FOR_FALLING_EDGE		; check to see if we received a falling edge interrupt

	;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
	; We received a falling edge interrupt 
	;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~		
	
	; Disable global interrupts and change the edge detection method to RISING EDGE DETECTION so that we don't
	; have to do it at the start of the next cycle
	cli									; disable global interrupts
	rcall	SET_RISING_EDGE_DETECTION	; switch to rising edge detection mode

	; Decide whether to turn the red or green light on.  0x0E is a magic number.  The result of the input 
	; response from the sensor is a 16-bit hex value that represents the roundtrip time of the sensor
	; pulse in microseconds.  Rather than using this value and turning it into a distance, which would
	; involve a pretty decent amount of math, I am comparing the high byte of the value 
	; to our magic number 0x0E.  This value gives us a cutoff distance of roughly 20.5 inches.  
	; This seems like a reasonable distance to park your car while leaving space to walk
	; between the front of your vehicle (or back if you decide to back in) and the wall.
	; If our high byte of our capture value is greater than 0x0E, we wil turn the green light on.
	; Otherwise, our high byte is lower than 0x0E so we will turn the red light on.
	cpi		CAPTURE_HIGH, 0x0E			; If our value is lower than 0x0E, turn the red light on.
	brlo	RED_ON						; Otherwise, turn the green light on.
	GREEN_ON:
	ldi		TEMP, 0xFD					; turn PA1 on.  Our output pin must go low to get current to flow
										; from the 5V supply (VTG) through our relay back to our pin
	out		PORTA, TEMP					; write out value to PORTA
	rjmp	MAIN_LOOP_RETURN			;
	RED_ON:
	ldi		TEMP, 0xFE					; turn PA0 on.  Again, our output pin needs to go low while we
										; drive the rest of the pins high
	out		PORTA, TEMP					; write our value to PORTA


	; Disable global interrupts so we can clear our IC4 flag and enable the timer0 overflow interrupt again
	cli
	MAIN_LOOP_RETURN:	
	clr		IC4_FLAG					; restart the IC4 flag register at 0
	rcall	ENABLE_TOV0					;

	; Reenable the global interrupts yet again, and wait for our timer0 overflow interrupt.
	; These delays will give our circuit time to settle and prevent the relays from seizing up.
	; A common problem of mechanical relays is they can't switch very fast, so if our circuit is constantly
	; trying to switch these, there is a very high probability that they will become stuck on.
	sei
	OVF2:
	cpi		TOV0_FLAG, 0x01				; is the TOV0 flag still 1?
	breq	OVF2						; If so, keep waiting for our timer0 overflow interrupt
	clr		TOV0_FLAG					; Otherwise, restart the timer0 overflow flag
	cli									; Disable global interrupts to restart the main loop
	rjmp	MAIN_LOOP					; 


ISR_TOV0:
	; Timer0 Overflow Interrupt Service Routine
	; This will simply increment our TOV0_FLAG register to let the main loop proceed
	inc		TOV0_FLAG					;
	reti


ISR_TIMER4_CAPT:
	; Timer4 Input Capture Interrupt Service Routine
	; Here we will capture our sensor read values.  Even though we only use the high byte, we must read the low
	; byte too.  More can be read about this in section 17.3 of the ATmega2560 datasheet.
	; After we get our sensor value, we will increment the IC4_FLAG.  We don't bother to check its value here
	; since we do all that logic in the main loop.  This will keep our interrupt routine shorter.
	; Lastly, we will restart the TCNT4 register to 0 so we can get a meaningful result from the measurement.
	lds		CAPTURE_LOW, ICR4L			; read low byte first (see 17.3 Accessing 16 Bit Registers in ATmega2560 data sheet)
	lds		CAPTURE_HIGH, ICR4H			;
	inc		IC4_FLAG					; increment the IC4 flag
	push	TEMP						; save TEMP register
	clr		TEMP						; clear TCNT4
	sts		TCNT4H, TEMP				; write to TCNT4H first (Section 17.3 ATmega2560 datasheet)
	sts		TCNT4L, TEMP				; write to TCNT4L only after writing to the high byte
	pop		TEMP						; restore TEMP register
	reti

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
; These subroutines are to make our program more readable when we must perform common tasks during
; the main loop
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
SET_DDRL0_OUTPUT:
	; Subroutine to set PORTL0 as an output
	push	TEMP						; save TEMP
	ldi		TEMP, 0x01					; PORTL0 direction must be high 
	sts		DDRL, TEMP					; 
	pop		TEMP						; restore TEMP
	ret									;

SET_DDRL0_INPUT:
	; Subroutine to set PORTL0 as an input
	push	TEMP						; save TEMP
	clr		TEMP						; PORTL0 direction must be low
	sts		DDRL, TEMP					; PORTL is outside the range of the OUT instruction so we must use STS
	pop		TEMP						; restore TEMP
	ret


PULSE_OUTPUT_PL0:
	; Subroutine to send a pulse output to PING sensor (PORTL0)
	push	TEMP						; save temp before starting
	clr		TEMP						; Now set the output low to clear the line
	sts		PORTL, TEMP					; PORTL is outside the range of the OUT instruction so we must use STS
	ldi		TEMP, (1 << PORTL0)			; Send a high pulse to the PING sensor
	sts		PORTL, TEMP					;
	nop									; a few nop's to let the output pulse settle at the input pin
	nop									; of the distance sensor
	nop									;
	clr		TEMP						; Clear the output line again by setting the output low
	sts		PORTL, TEMP					; PORTL is outside the range of the OUT instruction so we must use STS
	pop		TEMP						; restore temp
	ret									;

SET_RISING_EDGE_DETECTION:
	; Subroutine to change the edge detection method of Timer4 input capture to rising edge
	push	TEMP						; save TEMP register
	ldi		TEMP, (1 << ICNC4) | (1 << ICES4) | (1 << CS40) ; 1/1 prescaler, rising edge detection,
															; and noise cancellation
	sts		TCCR4B, TEMP				; TCCR4B = 0b11000001
	pop		TEMP						; restore TEMP register
	ret

SET_FALLING_EDGE_DETECTION:
	; Subroutine to change the edge detection method of Timer4 input capture to falling edge
	push	TEMP						; save TEMP register
	ldi		TEMP, (1 << ICNC4) | (1 << CS40) ; 1/1 prescaler, falling edge detection, and noise cancellation
	sts		TCCR4B, TEMP				;
	pop		TEMP						; restore TEMP register
	ret

ENABLE_TOV0:
	; Subroutine to enable the timer0 overflow interrupt
	push	TEMP							; save TEMP register
	ldi		TEMP, (1 << TOIE1)				; a 1 in the TOIE1 bit of TIMSK0 enables
											; the Timer0 Overflow Interrupt
	sts		TIMSK0, TEMP					;
	pop		TEMP							; restore TEMP register
	ret

DISABLE_TOV0:
	; Subroutine to disable the timer0 overflow interrupt
	push	TEMP							; save TEMP register
	clr		TEMP							; all 0's to TIMSK0 disables all Timer0 interrupts
	sts		TIMSK0, TEMP					; 
	pop		TEMP							; restore TEMP register
	ret