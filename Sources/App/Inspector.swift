#if DEBUG
  import AppKit
  import PalantirInspector
  import PalantirNotebookInspector

  extension AppDelegate {
    /// The inspector of the notebook window, with each feature's state section.
    func makeInspector() -> Inspector {
      Inspector(window: { [notebook] in notebook.window }, sections: [notebook.makeStateSection()])
    }
  }
#endif
