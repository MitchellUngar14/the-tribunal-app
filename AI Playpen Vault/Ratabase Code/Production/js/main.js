// On page load, check the user's saved mode preference in localStorage
document.addEventListener("DOMContentLoaded", function () {
    const modeToggle = document.getElementById("modeToggle");
    const modeLabel = document.getElementById("modeLabel");
    const body = document.body;

    // Check if the user has a saved preference in localStorage
    let savedMode = localStorage.getItem("theme");

    if (savedMode === "light-mode") {
        body.classList.remove("dark-mode");
        body.classList.add("light-mode");
        modeToggle.checked = false;
        modeLabel.innerText = "Light Mode";
    } else {
        body.classList.add("dark-mode");
        modeToggle.checked = true;
        modeLabel.innerText = "Dark Mode";
    }

    // Toggle between dark and light mode
    modeToggle.addEventListener("change", function () {
        if (this.checked) {
            body.classList.remove("light-mode");
            body.classList.add("dark-mode");
            modeLabel.innerText = "Dark Mode";
            // Save the preference to localStorage
            localStorage.setItem("theme", "dark-mode");
        } else {
            body.classList.remove("dark-mode");
            body.classList.add("light-mode");
            modeLabel.innerText = "Light Mode";
            // Save the preference to localStorage
            localStorage.setItem("theme", "light-mode");
        }
    });
});