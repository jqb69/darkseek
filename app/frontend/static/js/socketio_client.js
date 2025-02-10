// app/frontend/static/js/socketio_client.js (Error display and lazy loading)
const socket = io("ws://localhost:8000");

let allSearchResults = []; // Store all search results
let displayedResults = 0; // Track displayed results
const resultsPerLoad = 5; // Number of results to load at a time
let messagePlaceholder;

function displaySearchResults(results) {
    const searchResultsDiv = document.createElement('div');
    searchResultsDiv.id = 'search-results-container'; // Add an ID
    searchResultsDiv.innerHTML = '<strong>Search Results:</strong><br>';
    results.forEach(result => {
        const link = document.createElement('a');
        link.href = result.link;
        link.textContent = result.title;
        link.target = "_blank";
        searchResultsDiv.appendChild(link);
        searchResultsDiv.innerHTML += `<br>${result.snippet}<br>`;
    });
    messagePlaceholder.parentNode.insertBefore(searchResultsDiv, messagePlaceholder);
}

function addLoadMoreButton() {
    const loadMoreButton = document.createElement('button');
    loadMoreButton.textContent = 'Load More';
    loadMoreButton.id = 'load-more-button'; // Add an ID
    loadMoreButton.addEventListener('click', () => {
        displaySearchResults(allSearchResults.slice(displayedResults, displayedResults + resultsPerLoad));
        displayedResults += resultsPerLoad;
        if (displayedResults >= allSearchResults.length) {
            loadMoreButton.style.display = 'none'; // Hide button
        }
    });

    const searchResultsContainer = document.getElementById('search-results-container');
    if (searchResultsContainer) {
        searchResultsContainer.appendChild(loadMoreButton);
    }
}



socket.on("connect", () => {
    console.log("Connected to WebSocket");
    messagePlaceholder = document.querySelector("[data-testid='stText']"); // Get it here
});

socket.on("message", (data) => {
    const dataObj = JSON.parse(data);

    if (dataObj.error) {
        // Display errors in red
        const errorDiv = document.createElement('div');
        errorDiv.style.color = 'red';
        errorDiv.innerText = `Error: ${dataObj.error}`;
        messagePlaceholder.parentNode.insertBefore(errorDiv, messagePlaceholder);
    } else if (dataObj.type === 'llm_response') {
        messagePlaceholder.innerText += dataObj.content;
    } else if (dataObj.type === 'search_results') {
        allSearchResults.push(...dataObj.results); // Accumulate all results
        if (displayedResults === 0) { // Only display initial results once
            displaySearchResults(allSearchResults.slice(0, resultsPerLoad));
            displayedResults += resultsPerLoad;
            if (allSearchResults.length > resultsPerLoad) {
                addLoadMoreButton();
            }
        }
    } else if (dataObj.type === 'heartbeat') {
        console.log("Heartbeat received");
    }
});

socket.on("disconnect", () => {
    console.log("Disconnected from WebSocket. Reconnecting..."); // Reconnection is automatic
});

function sendInitialRequest(requestData) {
    socket.emit("message", JSON.stringify(requestData));
}

window.addEventListener('streamlit:session_data', (event) => {
    const requestData = event.detail;
    sendInitialRequest(requestData);
     allSearchResults = [];   // Reset search results on new query
     displayedResults = 0;
     const existingSearchResults = document.getElementById('search-results-container');
    if (existingSearchResults) { // Remove if it exists
      existingSearchResults.remove();
    }
});
