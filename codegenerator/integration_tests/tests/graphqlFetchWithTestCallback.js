const maxRetries = 200;
const retryTimeout = 2000; // 2s

let retries = 0;
// TODO: make this configurable
const endpoint = "http://localhost:8080/v1/graphql";

let shouldExitOnFailure = false;
/**
* Fetches a graphql query from local indexer instance and runs a test callback on the data
* @param {string} query - The graphql query to run 
* @param {string} restryFailureMessage - The message to display if the query fails after max retries
* @param {function: (queryData) => bool } testCallback - takes the query response and assert data is correct, returns shouldExitOnFailure for retries in this function
* @returns {void} - exits with 1 if maxRetries exceeded
*/
async function fetchQueryWithTestCallback(query, retryFailureMessage, testCallback) {
    if (retries >= maxRetries) {
        throw new Error(
            retryFailureMessage
        );
    }
    retries++;

    try {
        const response = await fetch(endpoint, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ query }),
        });

        const { data, errors } = await response.json();

        if (data) {
            console.log("returned data", data);
            shouldExitOnFailure = testCallback(data);
            return;
        } else {
            console.log("data not yet available, retrying in 2s");
        }

        if (errors) {
            console.error(errors);
        }
    } catch (err) {
        if (!shouldExitOnFailure) {
            console.log("[will retry] Could not request data from Hasura due to error: ", err);
            console.log("Hasura not yet started, retrying in 2s");
        } else {
            console.error(err);
            process.exit(1);
        }
    }
    setTimeout(() => { if (!shouldExitOnFailure) fetchQueryWithTestCallback(query, retryFailureMessage, testCallback) }, retryTimeout);
};

exports.fetchQueryWithTestCallback = fetchQueryWithTestCallback
