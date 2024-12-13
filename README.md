Jackson Philion, Oct.31.2024, jphilion@g.hmc.edu

**Brief Description**\
This repository contains the code for Lab 7 of E155 at Harvey Mudd College, taught by Prof Josh Brake. 

The system is designed to send a plaintext message from the MCU to the FPGA via SPI. Onboard the FPGA, it is put through a custom AES encryption program, before being shifted back out to the MCU via SPI.

The full write-up may be found on my portfolio website here: https://jacksonphilion.github.io/hmc-e155-portfolio/labs/lab7/lab7.html

**Structure**\
The `MCU` folder contains all custom libraries and the main.c source file necessary to run a complete SPI system between the MCU and FPGA. This code was given verbatim by Prof Brake in the Lab 7 Starter Code.

The `FPGA` folder contains a source folder, holding all of the source code (including aes.sv), as well as a radiant folder which holds the Lattice Radiant project files. All of my generative work may be found within the aes.sv file and the Radiant project – the rest was a part of the starter code package.

The `notesAndExtras` folder contains any additional notes, images, etc