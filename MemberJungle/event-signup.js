const getInputId = (labelText) =>
    [...document.querySelectorAll(`label`)].filter(
        (label) => label.innerText.trim() === labelText
    )[0]?.htmlFor;

const getInput = (labelText) => document.getElementById(getInputId(labelText));

function getCacheBustingUrl(url) {
    const timestamp = new Date().getTime();
    const separator = url.includes("?") ? "&" : "?";
    return `${url}${separator}cb=${timestamp}`;
}
function whichClubSDMA() {
    otherClub.parentElement.parentElement.style.display = "none";
}

function whichClubOther() {
    otherClub.parentElement.parentElement.style.display = "block";
    otherClub.setAttribute("required", true);
}

function vehicleOwnerMe() {
    vehicleOwnerFirstName.parentElement.parentElement.style.display = "none";
    vehicleOwnerLastName.parentElement.parentElement.style.display = "none";
    vehicleOwnerMobile.parentElement.parentElement.style.display = "none";
    vehicleOwnerFirstName.setAttribute("required", false);
    vehicleOwnerLastName.setAttribute("required", false);
    vehicleOwnerMobile.setAttribute("required", false);
}

function vehicleOwnerOther() {
    vehicleOwnerFirstName.parentElement.parentElement.style.display = "block";
    vehicleOwnerLastName.parentElement.parentElement.style.display = "block";
    vehicleOwnerMobile.parentElement.parentElement.style.display = "block";
    vehicleOwnerFirstName.setAttribute("required", true);
    vehicleOwnerLastName.setAttribute("required", true);
    vehicleOwnerMobile.setAttribute("required", true);
}

function whichCarNew() {
    bodyType.parentElement.parentElement.style.display = "block";
    year.parentElement.parentElement.style.display = "block";
    engineCapacity.parentElement.parentElement.style.display = "block";
    fuelType.parentElement.parentElement.style.display = "block";
    forcedInduction.parentElement.parentElement.style.display = "block";
    engineType.parentElement.parentElement.style.display = "block";
    bodyType.setAttribute("required", true);
    year.setAttribute("required", true);
    engineCapacity.setAttribute("required", true);
    fuelType.setAttribute("required", true);
    forcedInduction.setAttribute("required", true);
    engineType.setAttribute("required", true);
    insertNominateClassDetails();
    make.value = "";
    model.value = "";
    sdmaVehicleClass.value = "";
    sdmaCapacityClass.value = "";
}

function whichCarOld() {
    bodyType.parentElement.parentElement.style.display = "none";
    year.parentElement.parentElement.style.display = "none";
    engineCapacity.parentElement.parentElement.style.display = "none";
    fuelType.parentElement.parentElement.style.display = "none";
    forcedInduction.parentElement.parentElement.style.display = "none";
    engineType.parentElement.parentElement.style.display = "none";
    bodyType.setAttribute("required", false);
    year.setAttribute("required", false);
    engineCapacity.setAttribute("required", false);
    fuelType.setAttribute("required", false);
    forcedInduction.setAttribute("required", false);
    engineType.setAttribute("required", false);
    removeNominateClassDetails();
    lookupCarDatabase();
}
function insertNominateClassDetails() {
    const nominateClassDetailsHTML = `
    <div id="nominateClassDetails">
      <p>Nominate your vehicle class when assessed against the <a href="https://sdma.memberjungle.club/vehicle-class-details" target="_blank">SDMA Class Descriptions</a>. &nbsp;</p>
      <p>New cars will be scrutineered to confirm compliance with class rules. &nbsp;Existing competitors may be selected for a random inspection. &nbsp;All cars will be inspected at least once per year.</p>
    </div>
  `;
    document.getElementById("nominateClassDetailsContainer").innerHTML =
        nominateClassDetailsHTML;
}

function removeNominateClassDetails() {
    const nominateClassDetailsElement = document.getElementById(
        "nominateClassDetailsContainer"
    );
    if (nominateClassDetailsElement) {
        nominateClassDetailsElement.innerHTML = ""; // Clear the content
    }
}

function changesSinceLastEventNo() {
    descriptionOfChanges.parentElement.parentElement.style.display = "none";
    descriptionOfChanges.setAttribute("required", false);
}

function changesSinceLastEventYes() {
    descriptionOfChanges.parentElement.parentElement.style.display = "block";
    descriptionOfChanges.setAttribute("required", true);
}

function numofDrivers1() {
    driverB.parentElement.parentElement.style.display = "none";
    driverC.parentElement.parentElement.style.display = "none";
    driverB.setAttribute("required", false);
    driverC.setAttribute("required", false);
}

function numOfDrivers2() {
    driverB.parentElement.parentElement.style.display = "block";
    driverC.parentElement.parentElement.style.display = "none";
    driverB.setAttribute("required", true);
    driverC.setAttribute("required", false);
}

function numOfDrivers3() {
    driverB.parentElement.parentElement.style.display = "block";
    driverC.parentElement.parentElement.style.display = "block";
    driverB.setAttribute("required", true);
    driverC.setAttribute("required", true);
}

function callCapacityClass() {
    if (
        engineCapacity.value &&
        engineType.value &&
        fuelType.value &&
        forcedInduction.value &&
        sdmaVehicleClass.value
    ) {
        if (engineType.value === "ROTARY") {
            isRotary = true;
        } else {
            isRotary = false;
        }
        if (
            sdmaVehicleClass.value === "CLASS_G_TRACK__SPORTS_RACING" ||
            sdmaVehicleClass.value === "CLASS_H_TRACK__OPEN_WHEELER"
        ) {
            isSpecialClass = true;
        } else {
            isSpecialClass = false;
        }
        sdmaCapacityClass.value = calculateCapacityClass(
            engineCapacity.value,
            forcedInduction.value,
            fuelType.value,
            isRotary,
            isSpecialClass
        );
    }
}

function calculateCapacityClass(
    engineCap,
    forcedInductionStatus,
    fuelType,
    isRotary,
    isSpecialClass
) {
    // Turbo/supercharged have the engine capacity multiplied by 1.7. For Diesel multiply by 1.5.
    // Rotaries have the engine capacity multiplied by 1.8.
    // Turbo/supercharged rotaries have the engine capacity multiplied by 1.8 then 1.7 (net multiplier equals 3.06)

    let capacityMultiplier = 1;
    if (isRotary) {
        capacityMultiplier = 1.8;
    }
    if (isRotary && forcedInductionStatus != "NATURALLY_ASPIRATED") {
        capacityMultiplier = 3.06;
    }
    if (!isRotary && forcedInductionStatus != "NATURALLY_ASPIRATED") {
        if (fuelType === "DIESEL") {
            capacityMultiplier = 1.5;
        } else {
            capacityMultiplier = 1.7;
        }
    }

    engineCap = engineCap * capacityMultiplier;

    // Select correct Class
    if (!isSpecialClass) {
        if (engineCap <= 1600) {
            return "0 to 1600cc";
        } else if (engineCap <= 2000) {
            return "1601 to 2000cc";
        } else if (engineCap <= 3000) {
            return "2001 to 3000cc";
        } else {
            return "over 3000cc";
        }
    }
    if (isSpecialClass) {
        if (engineCap <= 750) {
            return "0 to 750cc";
        } else if (engineCap <= 1300) {
            return "751 to 1300cc";
        } else if (engineCap <= 2000) {
            return "1301 to 2000cc";
        } else {
            return "over 2000cc";
        }
    }
}

function lookupCarDatabase() {
    // Lookup JSON file for car details
    // JSON structure is as follows
    //   {
    //     "firstName": "Admin Lyall",
    //     "lastName": "Reid",
    //     "carDetails": {
    //       "make": "Subaru",
    //       "model": "WRX",
    //       "class": "C3",
    //       "capacity": "D"
    //     }
    //   }

    dbURL = getCacheBustingUrl(
        "https://sdma.memberjungle.club/content.cfm?page_id=2493554&current_category_code=25301"
    );

    console.log(dbURL);

    fetch(dbURL)
        .then((response) => response.json())
        .then((data) => {
            const carDetail = data.find(
                (person) =>
                    person.firstName === firstName.value &&
                    person.lastName === lastName.value
            );
            if (carDetail) {
                const classCode = carDetail.carDetails.class;
                const capacityCode = carDetail.carDetails.capacity;
                let className = "Unknown Class";
                let capacityValue = "Unknown Capacity";

                // Find the classes array
                const classesArray = data[0].classes;

                // Iterate through the classes array to find the class name and capacity value for C3
                for (const entry of classesArray) {
                    if (entry[classCode]) {
                        className = entry[classCode];
                        if (entry.Capacity && entry.Capacity[capacityCode]) {
                            capacityValue = entry.Capacity[capacityCode];
                        }
                        break;
                    }
                }
                make.value = carDetail.carDetails.make;
                model.value = carDetail.carDetails.model;

                // CLASS_A_ROAD__2WD
                // CLASS_B_ROAD__2WD
                // CLASS_C_ROAD__AWD
                // CLASS_D_ROAD__AWD
                // CLASS_E_ROAD__SPECIAL_VEHICLES
                // CLASS_F_TRACK__RACING_SEDANS
                // CLASS_G_TRACK__SPORTS_RACING
                // CLASS_H_TRACK__OPEN_WHEELER

                if (className === "Class A Road - 2WD") {
                    sdmaVehicleClass.value = "CLASS_A_ROAD__2WD";
                } else if (className === "Class B Road - 2WD") {
                    sdmaVehicleClass.value = "CLASS_B_ROAD__2WD";
                } else if (className === "Class C Road - AWD") {
                    sdmaVehicleClass.value = "CLASS_C_ROAD__AWD";
                } else if (className === "Class D Road - AWD") {
                    sdmaVehicleClass.value = "CLASS_D_ROAD__AWD";
                } else if (className === "Class E Road - Special Vehicles") {
                    sdmaVehicleClass.value = "CLASS_E_ROAD__SPECIAL_VEHICLES";
                } else if (className === "Class F Track - Racing Sedans") {
                    sdmaVehicleClass.value = "CLASS_F_TRACK__RACING_SEDANS";
                } else if (className === "Class G Track - Sports Racing") {
                    sdmaVehicleClass.value = "CLASS_G_TRACK__SPORTS_RACING";
                } else if (className === "Class H Track - Open Wheeler") {
                    sdmaVehicleClass.value = "CLASS_H_TRACK__OPEN_WHEELER";
                }
                sdmaCapacityClass.value = capacityValue;
            } else {
                if (!whichCar.parentElement.querySelector("small")) {
                    whichCar.parentElement.insertAdjacentHTML(
                        "beforeend",
                        "<small>No existing car is on record</small>"
                    );
                }
                whichCarNew();
                console.log("No car details found");
            }
        });
}
// ----------------------------------------------
// Field References
// ----------------------------------------------
const motorsportAustraliaLicenceNumber = getInput(
    "Motorsport Australia License Number"
);

const otherClub = getInput("Alternative club membership number");
const runningNumber = getInput("Running Number Request");
const vehicleOwnerFirstName = getInput("Vehicle Owner First Name");
const vehicleOwnerLastName = getInput("Vehicle Owner Last Name");
const vehicleOwnerMobile = getInput("Vehicle Owner Mobile");
const whichClub = document.getElementById("whichClub");
const vehicleOwner = document.getElementById("vehicleOwner");

const whichCar = document.getElementById("whichCar");
const firstName = getInput("First Name");
const lastName = getInput("Last Name");
const make = getInput("Make");
const model = getInput("Model");
const bodyType = getInput("Body Type");
const year = getInput("Year");
const engineCapacity = getInput("Exact Engine cc");
const fuelType = getInput("Fuel Type");
const forcedInduction = getInput("Aspiration");
const sdmaVehicleClass = getInput("SDMA Vehicle Class");
const sdmaCapacityClass = getInput("SDMA Capacity Class");
const engineType = getInput("Engine Type");
const changesSinceLastEvent = getInput("Changes since last event");
const descriptionOfChanges = getInput("Description of changes");
const numOfDrivers = getInput("Number of drivers this vehicle will have");
const driverB = getInput("Driver B");
const driverC = getInput("Driver C");

// ----------------------------------------------
// Set Initial Values
// ----------------------------------------------
// Validation
runningNumber.setAttribute("pattern", "[0-9]{1,2}");
motorsportAustraliaLicenceNumber.setAttribute("pattern", "[0-9]{6,8}");
motorsportAustraliaLicenceNumber.parentElement.insertAdjacentHTML(
    "beforeend",
    "<small>Speed Licence or higher: 6-8 digits</small>"
);

// whichClub
whichClubSDMA();

// vehicleOwner
vehicleOwnerMe();

// whichCar
sdmaVehicleClass.readOnly = true;
sdmaCapacityClass.readOnly = true;
whichCarOld();

// changesSinceLastEvent
changesSinceLastEventNo();

// number of drivers
numofDrivers1();

// ----------------------------------------------
// Event Listeners
// ----------------------------------------------

whichClub.addEventListener("change", () => {
    if (whichClub.checked) {
        whichClubOther();
    } else {
        whichClubSDMA();
    }
});

whichCar.addEventListener("change", () => {
    if (whichCar.checked) {
        whichCarNew();
    } else {
        whichCarOld();
    }
});

vehicleOwner.addEventListener("change", () => {
    if (vehicleOwner.checked) {
        vehicleOwnerOther();
    } else {
        vehicleOwnerMe();
    }
});

changesSinceLastEvent.addEventListener("change", () => {
    if (changesSinceLastEvent.value === "YES") {
        changesSinceLastEventYes();
    } else if (changesSinceLastEvent.value === "NO") {
        changesSinceLastEventNo();
    }
});

numOfDrivers.addEventListener("change", () => {
    console.log(numOfDrivers.value);
    if (numOfDrivers.value === "PD_1") {
        numofDrivers1();
    }
    if (numOfDrivers.value === "PD_2") {
        numOfDrivers2();
    }
    if (numOfDrivers.value === "PD_3") {
        numOfDrivers3();
    }
});

sdmaVehicleClass.addEventListener("change", () => {
    console.log(sdmaVehicleClass.value);
    callCapacityClass();
});

engineCapacity.addEventListener("change", () => {
    console.log(engineCapacity.value);
    callCapacityClass();
});

engineType.addEventListener("change", () => {
    console.log(engineType.value);
    callCapacityClass();
});

fuelType.addEventListener("change", () => {
    console.log(fuelType.value);
    callCapacityClass();
});

forcedInduction.addEventListener("change", () => {
    console.log(forcedInduction.value);
    callCapacityClass();
});

// Location of files
// Car Database
// https://sdma.memberjungle.club/content.cfm?page_id=2493554&current_category_code=25301
//
// Event Signup Javascript
// <script src="https://sdma.memberjungle.club/content.cfm?page_id=2493569&current_category_code=25301"></script>
