package fr.thomasmathis.planif.sante;

/**
 * Etat de sante d'un service ou d'une dependance.
 * Reprend le vocabulaire des sources de contraintes (5.2) pour rester coherent.
 */
public enum EtatSante {
    OK,
    DEGRADE,
    MORT
}
