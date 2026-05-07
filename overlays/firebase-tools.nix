_: prev: {
  firebase-tools = prev.firebase-tools.override {
    buildNpmPackage = prev.buildNpmPackage.override {
      nodejs = prev.nodejs_20;
    };
  };
}
