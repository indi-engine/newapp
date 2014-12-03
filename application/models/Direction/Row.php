<?php
class Direction_Row extends Indi_Db_Table_Row {

    /**
     * 
     *
     * @return int
     */
    public function save(){

        if ($this->id) return false;

        // Detect monthId
        list($y, $m) = explode('-', $this->date);
        $this->monthId = Indi::model('Month')->fetchRow('`month` = "' . $m . '" AND `yearId` = "'
            . Indi::model('Year')->fetchRow('`title` = "' . $y . '"')->id . '"')->id;

        // Setup title
        $this->title = $this->date . ' ' . $this->foreign('patientId')->title;

        // Perform native mismatch check. If any actual mismatch was detected - return
        $this->mismatch(true); if (count($this->mismatch())) return false;

        // Try to find complex tariff for doctor
        if (!$doctorTariffR = $this->foreign('doctorId')->tariff()) $this->mismatch('doctorId', 'Этот врач на текущий момент не имеет тарифа');

        // Try to find complex tariff for clinic
        if (!$clinicTariffR = $this->foreign('clinicId')->tariff()) $this->mismatch('clinicId', 'Этот направитель на текущий момент не имеет тарифа');

        // If any actual mismatch was detected - return
        if (count($this->mismatch())) return false;

        // Shortcut to Accural model
        $accuralM = Indi::model('Accural');

        // Get the entry, representing an accural summary for a clinic,
        // within the current month, or create it, if it is not yet exist
        if (!$clinicAccuralR = $accuralM->fetchRow(array(
            '`clinicId` = "' . $this->clinicId .'"', '`monthId` = "' . $this->monthId .'"', '`for` = "clinic"',
        ))) {

            // Create new
            $clinicAccuralR = $accuralM->createRow()->assign(array(
                'clinicId' => $this->clinicId,
                'monthId' => $this->monthId,
                'for' => 'clinic',
                'accuralId' => 0,
                'fixedTariffId' => $clinicTariffR->fixedTariffId,
                'floatTariffId' => $clinicTariffR->floatTariffId,
                'chiefTariffId' => $clinicTariffR->chiefTariffId,
                'salary' => $clinicTariffR->salary,
                'bloodPrice' => $clinicTariffR->blood,
                'smearPrice' => $clinicTariffR->smear,
            ));

            // If try to save is unsuccessful
            if (!$clinicAccuralR->save()) {

                // Setup error message
                $this->mismatch('#clinicAccural', 'Mismatch detected while trying: $clinicAccuralR->save()');

                // Return
                return false;
            }
        }

        // Get the entry, representing an accural summary for a doctor,
        // within the current month, or create it, if it is not yet exist
        if (!$doctorAccuralR = $accuralM->fetchRow(array(
            '`doctorId` = "' . $this->doctorId .'"', '`monthId` = "' . $this->monthId .'"',
            '`for` = "doctor"', '`clinicId` = "'. $this->clinicId . '"'
        ))) {

            // Create new
            $doctorAccuralR = $accuralM->createRow()->assign(array(
                'doctorId' => $this->doctorId,
                'clinicId' => $this->clinicId,
                'monthId' => $this->monthId,
                'for' => 'doctor',
                'accuralId' => $clinicAccuralR->id,
                'fixedTariffId' => $doctorTariffR->fixedTariffId,
                'floatTariffId' => $doctorTariffR->floatTariffId,
                'salary' => $doctorTariffR->salary,
            ));

            // If try to create is unsuccessful
            if (!$doctorAccuralR->save()) {

                // Setup error message
                $this->mismatch('#doctorAccural', 'Mismatch detected while trying: $doctorAccuralR->save()');

                // Return
                return false;
            }
        }

        // Detect blood and smear service ids, as those have special behaviour
        $serviceRId_blood = Indi::model('Service')->fetchRow('`title` = "Забор материала кровь"')->id;
        $serviceRId_smear = Indi::model('Service')->fetchRow('`title` = "Забор материала мазок"')->id;

        // If blood is in the list of ordered services, increase qty and sum for it within clinic accural entry
        if (in($serviceRId_blood, $this->serviceIds)) {
            $clinicAccuralR->bloodQty ++;
            $clinicAccuralR->bloodSum += $clinicTariffR->blood;
        }

        // If smear is in the list of ordered services, increase qty and sum for it within clinic accural entry
        if (in($serviceRId_smear, $this->serviceIds)) {
            $clinicAccuralR->smearQty ++;
            $clinicAccuralR->smearSum += $clinicTariffR->smear;
        }

        // Backup serviceIds
        $serviceIds_backup = $this->serviceIds;

        // Unset blood and smear from list of service ids, so serviceIds wil contain
        // ids of all other ordered services (other - mean excluding smear and blood)
        $this->serviceIds = implode(',', un($this->serviceIds, array($serviceRId_blood, $serviceRId_smear)));

        // If there actually was at least one non-blood/smear service
        if ($this->serviceIds) {

            // Get the groups ids of that other ordered services
            $serviceGroupIdA = $this->foreign('serviceIds')->column('serviceGroupId');

            // Update *Qty and *Sum for fixed, float and chief tariffs within clinic's accural
            foreach (ar('fixed,float,chief') as $type) {
                $tariffServiceGroupRs = $clinicAccuralR->foreign($type . 'TariffId')->nested('tariffServiceGroup');
                foreach ($serviceGroupIdA as $serviceGroupId) {
                    if ($tariffServiceGroupR = $tariffServiceGroupRs->select($serviceGroupId, 'serviceGroupId')->at(0)) {
                        $clinicAccuralR->{$type . 'TariffQty'} ++;
                        if ($tariffServiceGroupR->measure == 'rub') {
                            $clinicAccuralR->{$type . 'TariffSum'} += $tariffServiceGroupR->price;
                        } else if ($tariffServiceGroupR->measure == 'percent') {
                            $clinicAccuralR->{$type . 'TariffSum'} += $tariffServiceGroupR->price;
                        }
                    }
                }
            }

            // Update *Qty and *Sum for fixed and float tariffs within doctor's accural
            foreach (ar('fixed,float') as $type) {
                $tariffServiceGroupRs = $doctorAccuralR->foreign($type . 'TariffId')->nested('tariffServiceGroup');
                foreach ($serviceGroupIdA as $serviceGroupId) {
                    if ($tariffServiceGroupR = $tariffServiceGroupRs->select($serviceGroupId, 'serviceGroupId')->at(0)) {
                        $doctorAccuralR->{$type . 'TariffQty'} ++;
                        if ($tariffServiceGroupR->measure == 'rub') {
                            $doctorAccuralR->{$type . 'TariffSum'} += $tariffServiceGroupR->price;
                        } else if ($tariffServiceGroupR->measure == 'percent') {
                            $doctorAccuralR->{$type . 'TariffSum'} += $tariffServiceGroupR->price;
                        }
                    }
                }
            }
        }

        // Restore the initial value of `serviceIds` property
        $this->serviceIds = $serviceIds_backup;

        // Update *Qty and *Sum for a clinic's accural
        $clinicAccuralR->save(); if ($clinicAccuralR->mismatch()) {
            $this->mismatch('#clinicAccural', 'Problem with *Qty and *Sum props update for a clinic accural');
            return false;
        }

        // Update *Qty and *Sum for a doctor's accural
        $doctorAccuralR->save(); if ($doctorAccuralR->mismatch()) {
            $this->mismatch('#doctorAccural', 'Problem with *Qty and *Sum props update for a doctor accural');
            return false;
        }

        // Standard save
        return parent::save();
    }
}