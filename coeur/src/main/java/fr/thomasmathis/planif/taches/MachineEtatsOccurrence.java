package fr.thomasmathis.planif.taches;

import java.util.EnumMap;
import java.util.EnumSet;
import java.util.Map;
import java.util.Set;

import org.springframework.http.HttpStatus;

import fr.thomasmathis.planif.commun.ExceptionMetier;

/**
 * Transitions autorisees entre etats d'occurrence (cf. cahier des charges, 5.3).
 *
 * <p>Un seul endroit dans le code decide de ce qui est permis. Toute tentative
 * de transition interdite leve une erreur metier explicite plutot que de laisser
 * une occurrence dans un etat incoherent.</p>
 */
public final class MachineEtatsOccurrence {

    private static final Map<EtatOccurrence, Set<EtatOccurrence>> TRANSITIONS =
            new EnumMap<>(EtatOccurrence.class);

    static {
        TRANSITIONS.put(EtatOccurrence.PLANIFIEE, EnumSet.of(
                EtatOccurrence.NOTIFIEE,
                EtatOccurrence.VALIDEE,       // validation retroactive sans notification prealable
                EtatOccurrence.REPORTEE,
                EtatOccurrence.REFUSEE,
                EtatOccurrence.GELEE,
                EtatOccurrence.NON_PLANIFIABLE,
                EtatOccurrence.ANNULEE));

        TRANSITIONS.put(EtatOccurrence.NOTIFIEE, EnumSet.of(
                EtatOccurrence.VALIDEE,
                EtatOccurrence.REPORTEE,
                EtatOccurrence.REFUSEE,
                EtatOccurrence.GELEE,
                EtatOccurrence.ANNULEE));

        // Degel : retour a PLANIFIEE, jamais directement a NOTIFIEE.
        TRANSITIONS.put(EtatOccurrence.GELEE, EnumSet.of(
                EtatOccurrence.PLANIFIEE,
                EtatOccurrence.ANNULEE));

        // Une occurrence non plaçable reste visible et peut retrouver une place
        // a la replanification suivante.
        TRANSITIONS.put(EtatOccurrence.NON_PLANIFIABLE, EnumSet.of(
                EtatOccurrence.PLANIFIEE,
                EtatOccurrence.VALIDEE,
                EtatOccurrence.GELEE,
                EtatOccurrence.ANNULEE));

        TRANSITIONS.put(EtatOccurrence.VALIDEE, EnumSet.noneOf(EtatOccurrence.class));
        TRANSITIONS.put(EtatOccurrence.REPORTEE, EnumSet.noneOf(EtatOccurrence.class));
        TRANSITIONS.put(EtatOccurrence.REFUSEE, EnumSet.noneOf(EtatOccurrence.class));
        TRANSITIONS.put(EtatOccurrence.ANNULEE, EnumSet.noneOf(EtatOccurrence.class));
    }

    private MachineEtatsOccurrence() {
    }

    public static boolean transitionAutorisee(EtatOccurrence depuis, EtatOccurrence vers) {
        return TRANSITIONS.getOrDefault(depuis, EnumSet.noneOf(EtatOccurrence.class)).contains(vers);
    }

    public static Set<EtatOccurrence> transitionsPossibles(EtatOccurrence depuis) {
        return EnumSet.copyOf(TRANSITIONS.getOrDefault(depuis, EnumSet.noneOf(EtatOccurrence.class)));
    }

    /**
     * Applique la transition ou leve une erreur metier.
     * C'est le seul chemin par lequel l'etat d'une occurrence change.
     */
    public static void appliquer(OccurrenceTache occurrence, EtatOccurrence vers) {
        EtatOccurrence depuis = occurrence.getEtat();

        // Reappliquer un etat non terminal est sans effet : une notification
        // renvoyee ne doit pas echouer. Mais revalider une occurrence deja
        // validee doit etre refuse, sinon une double validation ecraserait la
        // date reelle et decalerait toute la recurrence.
        if (depuis == vers && !depuis.estTerminal()) {
            return;
        }
        if (!transitionAutorisee(depuis, vers)) {
            throw new ExceptionMetier(
                    "TRANSITION_INTERDITE",
                    HttpStatus.CONFLICT,
                    "Transition %s vers %s interdite pour l'occurrence %s".formatted(depuis, vers, occurrence.getId()));
        }
        occurrence.appliquerEtat(vers);
    }
}
