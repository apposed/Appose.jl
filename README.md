# Appose.jl

## What is Appose?

Appose is a library for interprocess cooperation with shared memory.
The guiding principles are *simplicity* and *efficiency*.

Appose was written to enable **easy execution of Python-based deep learning
from other languages without copying tensors**, but its utility extends beyond
that. The steps for using Appose are:

* Build an Environment with the dependencies you need.
* Create a Service linked to a *worker*, which runs in its own process.
* Execute scripts on the worker by launching Tasks.
* Receive status updates from the task asynchronously via callbacks.

For more about Appose as a whole, see https://apposed.org.

## What is this project?

This is the **Julia implementation of Appose**.

## How do I use it?

TODO

## Examples

Here is a minimal example for calling into Python from Julia:

```julia
TODO
```

It requires your active/system Julia to have ... TODO

Here is an example using a few more of Appose's features:

```julia
TODO
```

Of course, the above examples could have been done all in one language. But
hopefully they hint at the possibilities of easy cross-language integration.

## Issue tracker

All implementations of Appose use the same issue tracker:

https://github.com/apposed/appose/issues
