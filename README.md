### zlisp
A lisp dialect written in Zig, to be used as a scripting language in Zen+ 

#### objects
`zlisp` has first class support for objects, with syntax similar to `javascript` `objects` -- this is 
because in `Zen+` objects are just as important as lists, for creating sequencers with rich data.

```
(set stepData { stepNumber 0 time 123 })
// merging
(set newStepData { ... stepData transpose 4})
```
