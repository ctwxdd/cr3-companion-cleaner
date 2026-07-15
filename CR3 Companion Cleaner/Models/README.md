# Replacing the blur model

The rest of the app depends only on the `BlurDetecting` protocol in
`BlurDetection.swift`. The bundled `CoreMLBlurDetector` adapter is configured
by `BlurModelConfiguration.bundled`.

A drop-in replacement must:

- accept an RGB image named `image`;
- resize through Vision to the model's declared image dimensions;
- return an MLMultiArray named `probabilities`;
- order that array as `[sharp, blurred]`.

Replace `Resources/BlurDetector.mlmodelc` to swap a compatible model. For a
model with different input/output semantics, add another `BlurDetecting`
adapter and change only its construction in `CleanerViewModel.analyzeBlur()`.

The included model is a Core ML conversion of
`bradduy/MagikaDocumentFromPixel`, used under its MIT license. The source
`.mlpackage` is retained here for inspection and future recompilation.
