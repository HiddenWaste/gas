# The Glassian Autonomous System

Revisiting this Idea from my second research project.

The idea is to have a musical system that (from beginning parameters) evolves and changes overtime in automatic and or interactive ways. A file containing a unique data structure outlines the composition that the system uses. The instruments used, their starting pattern outlines, musical constraints of the piece, etc. The pattern engine takes those constraints to calculate not only when 'mutations' or 'changes' happen, but the direction and strength of those changes. Again, defined in the composition structure.

When I first had a rudimentary version running, it was quite enjoyable. Constantly evolving musical textures which could be expanded and customized in many ways. Exploring different musical constraints, incorporating unique samples or new synthdefs, or just messing with numbers and seeing what happens!

I use the word 'system' very particularly as its meant to also be able to be interacted with! Pulling information through DSP, current variable values, or running commands to affect it in real time, or maybe to queue events. Its meant to be a means of reading a composition that can then be turned into a sort of performance. As no two runs of the system are never the same, even with the same 'composition'

# The Composition
I use the term 'unique data structure' as its a file with specific variables and breakdown to be readable programmatically by an interpreter. 

Revisiting this was definitely interesting. I think a lot of it could really be refined and made more efficient both in terms of amount of code, and variables in memory and such. I think a decent breakdown to still include would be:

- system
    - Main Volume
    - (maybe fold timing into this?)
- instruments
    - instruments used
    - starting volumes
    - 'style's??
- musical constraints
    - key, mode, etc
    - max min values
        - pitch
- timeline
    - mode changes 
    - loops 
    - instruments in and out
    - the actual 'composition' in a way

Part of me thinks there is only a certain amount of pattern definition I'd want to incorporate into this file for sake of length, but at the same time perhaps thats sacrificing customization to the piece and starting templates can be made to make it less daunting. 

Folding the system audio and timing into one system portion makes more sense in my head, especially for trying to call the information elsewhere. The instruments vs patterns debate for what goes where is also a cause of confusion for me. The timeline is a decently defined portion of this that I don't think needs many changes other than being able to loop. But only some pieces would want to loop anyways so no overarching structure for that. 

# Sample Manager
This can be thrown away for now in favor of what I did before and just have a synthdefs.scd with a few simple synthdefs to test the system with. 

# Pattern Engine
Its been long enough now when I look at this, the state manager, the musical constraints, I can't help but think it could be simplified more. But perhaps this object oriented approach is also for the better. Either way the patterng engine with these things is the heart of the system that drives and handles the evolution functions that are called by the interpreter. 

# Influences
If I had to pick one piece that influenced this the most it would be Phillip Glass's Einstein on The Beach. The minimalist approach in music of having patterns that phase in and out of each other over time and how slight changes in the structure of the underlying patterns can create such complexity from simplicity. A form of emergence. This combined with my already heavy interest in creating new musical systems or systems to make music with and I love the idea of being able to just write a file preset and feed it to a system and make new compositions that way
