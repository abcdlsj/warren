import { createRoot } from "react-dom/client";

import App from "./App.jsx";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Warren Web root element is missing");
}

createRoot(root).render(<App />);
