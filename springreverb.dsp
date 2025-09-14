declare filename "reverb.dsp";
declare name "reverb";
// Spring reverb effect for Chaos Audio Stratus
// By Daniel Leonov, daleonov7 (at) gmail (dot) com
// Created on may 6-7, 2025

import ("stdfaust.lib");

declare stratusId "87dcbb9d-895d-4036-be7e-108d0aad1c5e";
declare stratusVersion "1.0.33";
declare filename "springreverb.dsp";
declare name "Spring Reverb";

sample_rate_hz = 44100;  // For Stratus
// sample_rate_hz = ma.SR;  // For plugins 

// "Dwell"
// Sweep: ({0.0, 0.26}, {5.0, 0.31}, {10.0, 0.33})
// https://www.wolframalpha.com/input?i=quadratic+fit+calculator&assumption=%7B%22F%22%2C+%22QuadraticFitCalculator%22%2C+%22data%22%7D+-%3E%22%28%7B0.0%2C+0.26%7D%2C+%7B5.0%2C+0.31%7D%2C+%7B10.0%2C+0.33%7D%29%22
dwell = hslider ("Dwell[style:knob][stratus:0]", 5, 0, 10, 0.1);
feedback_gain_linear = dwell * (-0.0006 * dwell + 0.013) + 0.26;

// "Blend"
// Keeping it linear to save CPU
blend = hslider ("Blend[style:knob][stratus:1]", 5, 0, 10, 0.1);
wet_gain_linear = blend * 0.08;

// "Tone"
// Affects only wet signal, aplies some makeup gain to compensate for lost HF energy
// Sweep: ({0.0, 1500}, {5.0, 6000}, {10.0, 20000})
// https://www.wolframalpha.com/input?i=quadratic+fit+calculator&assumption=%7B%22F%22%2C+%22QuadraticFitCalculator%22%2C+%22data%22%7D+-%3E%22%28%7B0.0%2C+1500%7D%2C+%7B5.0%2C+6000%7D%2C+%7B10.0%2C+20000%7D%29%22
tone = hslider ("Tone[style:knob][stratus:2]", 5, 0, 10, 0.1);
lowpass_freq_hz = tone * (190 * tone + 50) + 1500;
makeup_gain = 0.5 * min (5, 1 + 2000 / lowpass_freq_hz);

// "Tension"
// Affects base delay time of main delay lines. Higher delays result in more lush sound, but with noticeable predelay.
// Lower values result in less diffused sound. This control feels like changing tightness of the springs, although I have no idea if real world spring reverbs would react to tension this way. But who cares.
// It affects the tail length, along with "Dwell" control.
// Sweep: ({0.0, 0.07}, {5.0, 0.042}, {10.0, 0.03})
// https://www.wolframalpha.com/input?i=quadratic+fit+calculator&assumption=%7B%22F%22%2C+%22QuadraticFitCalculator%22%2C+%22data%22%7D+-%3E%22%28%7B0.0%2C+0.07%7D%2C+%7B5.0%2C+0.042%7D%2C+%7B10.0%2C+0.03%7D%29%22
tension = hslider ("Tension[style:knob][stratus:3]", 5, 0, 10, 0.1);
base_spring_delay_s = tension * (0.00032 * tension - 0.0072) + 0.07; 

// "Springs"
// Determines how far apart delay times are in the main delay lines. Close timings result in more metallic sound, more spread out ones sound more.
// Inspired by similar control in "Hot Springs" from Line6 Helix, but more extreme.
// Doesn't really change amount of delay lines or anything like this, just produces such an effect.
// 0 = left, 2 = middle, 1 = right
springs = nentry ("Springs[style:switch][stratus:1]", 2, 0, 2, 1);
spread = select3 (springs, 0.2e-5, 5.0e-4, 2.8e-5);

diffusion_delay_max_samples = 0.035 * sample_rate_hz : round;  // Should be large enough to accomodate largest delay length returned by diffusion_delay_samples()
spring_delay_max_samples = 0.08 * sample_rate_hz : round;  // Should be >= than largest value returned by spring_delay_samples()
spring_comb_filter_delay_max_samples = 0.13 * sample_rate_hz : round;  // Should be >= than largest value returned by spring_comb_filter_delay_samples()
N = 8;  // Number of diffusion and delay lines

// Calculates delay time in samples for each delay line
// min_..max_ - target delay time range in seconds
// bins - number of bins (intervals) in that delay range, each parallel bus line is working on it its own bin
// bin - number of the bin
diffusion_delay_samples (min_, max_, bin, bins) = 
    abs (min_ + ((max_ - min_) / bins) * bin) * sample_rate_hz : round;

// Initial diffusion. Long enough to sound like a reverb instead of slapback delay,
// but short enough to not smear the "springiness" of the reverb that comes after it.
// The delay lengths are pretty arbitrary here.
diffusion =
    par (i, N, de.delay (diffusion_delay_samples (0.05, 0.020, i, 8), diffusion_delay_max_samples))
    : ro.hadamard (N)
    : polarity_flips_a
    : par (i, N, de.delay (diffusion_delay_samples (0.009, 0.030, i, N), diffusion_delay_max_samples))
    : ro.hadamard (N)
    : polarity_flips_b
    : par (i, N, de.delay (diffusion_delay_samples (0.010, 0.025, i, N), diffusion_delay_max_samples))
    : ro.hadamard (N)
    : polarity_flips_c
    : par (i, N, de.delay (diffusion_delay_samples (0.009, 0.032, i, N), diffusion_delay_max_samples))
with {
    // Polarity plips are optional, but why not?
    polarity_flips_a = _, *(-1), _, _, *(-1), _, *(-1), *(-1);  // 2 5 6 7
    polarity_flips_b = *(-1), _, _, *(-1), _, _, _, *(-1);  // 1 4 8
    polarity_flips_c = _, *(-1), *(-1), _, _, _, *(-1), _;  // 2 3 7
};

// Basic building block for delay lines
// Replacing generic LPF with a ve.lowpassLadder4 (1, lp) sounds cool, but hard to dial in for the entire "Tone" knob range
// and more CPU intensive (extra 5% CPU or so), but worth exploring in the future.
spring (d, lp) = de.delay (spring_delay_max_samples, d) : fi.lowpass (1, lp);

spring_delay_samples (i) = 
    (base_spring_delay_s + ba.take (i + 1, offsets) * spread) * sample_rate_hz : round
with {

    // No particular reason for them being prime numbers, but those values worked the best so far.
    // String mode based ones sound cool too, with slightly detuned values, but perhaps not for a spring reverb.
    // Like this: offsets = 1, 1.002, 1.003, 1.00, 2, 2.0001, 1.50002, 3.00;  
    offsets = 1, 2, 3, 5, 7, 11, 13, 17;
};


// This is meat and potatoes of this reverb. I've found this design with those timings to have the best "springy" character.
// fi.fb_comb() before clipper (but after feedback loops) adds some extra funkiness on top, with similar delays to the main feedback delays.
// Like this: fi.fb_comb (spring_comb_filter_delay_max_samples, spring_comb_filter_delay_samples (i), 0.9, 0.1).
delay_lines = par (i, N, spring (spring_delay_samples (i), lowpass_freq_hz) : aa.hardclip);


// Introduces crosstalk between indicidual channels, so instead of
// having N individual feedback loops, we have one multi-channel loop.
feedback_lines = ro.hadamard (N) : par (i, N, * (feedback_gain_linear));

// Diffuse -> Delay lines with feebback loop
reverb = _ * (0.01) <: diffusion: (si.bus (N * 2) :> delay_lines) ~ (feedback_lines) :> fi.highpass (1, 150) : * (makeup_gain) : _;
process = _ <: (_, wet_gain_linear * reverb) :> _ ;
