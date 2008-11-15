/*
    Cahors, by Jamie Matthews.
    A MIDI sequencer for the Arduino physical computing platform

    This file is part of Cahors.
    
    Cahors is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Cahors is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Cahors.  If not, see <http://www.gnu.org/licenses/>.
*/


#include <avr/pgmspace.h>

// Variables: 

#define  switch_pin   2    // to start sketch running
#define  led_pin      13   // for noteoff full warning
#define  noteoff_size 32   // size of the noteoff arrays in memory
#define  mask         0x80 // used for drum patterns. b10000000

#include "util.h"
#include "song.h"

int pause = (int) (60000 / bpm) / 8;

unsigned int tick_counter = 0;
int bar_counter = 0;
int tpb = 32; // ticks per bar

// Noteoff arrays.
// Used to keep track of and trigger noteOff messages
int  noteoff_times[noteoff_size];
byte noteoff_notes[noteoff_size];
byte noteoff_chans[noteoff_size];


void setup() 
{
  //  Set MIDI baud rate:
  Serial.begin(31250);
  pinMode(led_pin, OUTPUT);
  
  // Set channels
  for (int ch=0; ch<melody_count; ch++)
  {
    byte the_chan =  pgm_read_byte(&(chan_voices[ch][chann]));
    byte the_voice = pgm_read_byte(&(chan_voices[ch][voice]));
    program_change(the_chan, the_voice);
    
    // All notes and sound off for this channel (to stop stuck notes if reset)
    midimsg( 0xB0 | the_chan, 0x78, 0);
    midimsg( 0xB0 | the_chan, 0x7B, 0);
  }
  
  // Waits for button press to start sketch.
  while(digitalRead(switch_pin))
  {
    digitalWrite(led_pin, HIGH);
    delay(100);
    digitalWrite(led_pin, LOW);
    delay(100);
  }
  
  
}

void loop() 
{
  // Keep track of time when loop started
  unsigned long start_time = millis();
  
  // First, deal with any Note Offs which need to be sent.
  check_noteoffs(tick_counter);
  
  // Update current position in the bar, 0 -> 31
  int position = tick_counter % tpb;
    
  //-----------------------------------------------------------
  // DRUM PATTERN
  //-----------------------------------------------------------
  
  // Pointer to current pattern
  prog_uchar * current_drum_pat = (prog_uchar*) pgm_read_word(&song[bar_counter][drums]);
  
  for (int p=0; p<4; p++) 
  {
    // read the current pattern from flash memory
    byte this_pattern[4];
    for (int b=0; b<4; b++) this_pattern[b] = pgm_read_byte(&(current_drum_pat[7*p +pat_b1+b]));
    
    if ( this_pattern[position/8] << position%8 & mask ) // note should be played!
    {
      // Get the data for the current pattern out of flash memory
      byte this_note =     pgm_read_byte(&(current_drum_pat[7*p+pat_note]));
      byte this_duration = pgm_read_byte(&(current_drum_pat[7*p+pat_duration]));
      byte this_velocity = pgm_read_byte(&(current_drum_pat[7*p+pat_velocity]));

      noteon(drumchan, this_note, this_velocity);
      add_noteoff(this_note, drumchan, tick_counter+this_duration);
    }
  }
  
  //-----------------------------------------------------------
  // MELODIES
  //-----------------------------------------------------------
  
  // Loop through each melody
  for (int current_mel=first_mel; current_mel<melody_count+1; current_mel++)
  {
    // Pointer to current melody
    prog_uchar * current_mel_p = (prog_uchar*) pgm_read_word(&song[bar_counter][current_mel]);
    
    // Channel number for current melody
    byte current_chan = pgm_read_byte(&(chan_voices[current_mel-first_mel][chann]));
  
    int index = 0;
    byte this_beat = pgm_read_byte(&(current_mel_p[4*index+mel_beat]));
   
    while (this_beat != END) // Go through all the beats in the melody pattern
    {
      if (this_beat == position) // Note needs to be played here!
      {
        byte this_note =     pgm_read_byte(&(current_mel_p[4*index+mel_note]));
        byte this_duration = pgm_read_byte(&(current_mel_p[4*index+mel_duration]));
        byte this_velocity = pgm_read_byte(&(current_mel_p[4*index+mel_velocity]));
  
        noteon(current_chan, this_note, this_velocity);
        add_noteoff(this_note, current_chan, tick_counter+this_duration);
      }
    
      index++;
      this_beat = pgm_read_byte(&(current_mel_p[4*index+mel_beat]));
    }
  }
  
  //-----------------------------------------------------------
  // TIMEKEEPING
  //-----------------------------------------------------------
  
  tick_counter++;
  
  if (tick_counter % tpb == 0 && tick_counter != 0) // We have reached the end of the bar
  {
    bar_counter++;
  
    // Check for end of song
    prog_uchar * next = (prog_uchar*) pgm_read_word(&song[bar_counter][0]);
    //if (pgm_read_byte(&(next[0])) == END) bar_counter = 0; // if we're at the end, restart.
    if (pgm_read_byte(&(next[0])) == END) 
    {
      bar_counter = 0; // if we're at the end, restart.
      setup();
    }
  }
  
  // Pause before next tick.
  while (millis() < start_time + pause) {} 
  
} // end of loop()



//-----------------------------------------------------------
// Functions to handle the Note Off arrays.
//-----------------------------------------------------------

// Add a note to the noteoff arrays
void add_noteoff(byte note, byte chan, unsigned int time)
{
  int i = 0;
  while(noteoff_times[i]) i++; // find an empty slot
  
  if (i == noteoff_size) // array is full!
  {
    digitalWrite(led_pin,HIGH);
  }
  else
  {
    noteoff_times[i] = time;
    noteoff_notes[i] = note;
    noteoff_chans[i] = chan;
    digitalWrite(led_pin, LOW);
  }
}

// Checks the noteoff arrays and sends appropriate noteoffs
void check_noteoffs(unsigned int couter)
{
  for (int i = 0; i<noteoff_size; i++)
  {
    if (noteoff_times[i] == tick_counter)
    {
      noteoff(noteoff_chans[i], noteoff_notes[i]);
      noteoff_times[i] = 0; // slot is now empty
    }
  }
}

//-----------------------------------------------------------
// MIDI message sending functions
//-----------------------------------------------------------

void noteon(byte channel, byte note, byte velocity) 
{
  midimsg( 0x90 | channel, note, velocity);
}

void noteoff(byte channel, byte note) 
{
  midimsg( 0x80 | channel, note, 0);
}

void program_change(byte channel, byte progno) 
{
  midimsg( 0xC0 | channel, progno);
}

// Three-byte MIDI message
void midimsg(byte cmd, byte data1, byte data2) 
{
  Serial.print(cmd, BYTE);
  Serial.print(data1, BYTE);
  Serial.print(data2, BYTE);
}

// Two-byte MIDI message
void midimsg(byte cmd, byte data1) 
{
  Serial.print(cmd, BYTE);
  Serial.print(data1, BYTE);
}


