package fr.thomasmathis.planif.taches;

/**
 * Types de dependance entre definitions.
 *
 * <p>Un seul type en v1 : la tache cible doit etre faite dans les N heures
 * suivant la validation de la source, et jamais avant elle (7.4 D.4).</p>
 */
public enum TypeDependance {
    DECLENCHE_APRES
}
